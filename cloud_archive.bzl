""" This rule will download an archive from Minio, Google Storage, S3 or
Backblaze, check sha256, extract it, and symlink the provided BUILD file
inside. """

# License: Apache 2.0
# Provenance: https://github.com/1e100/cloud_archive

load("@bazel_tools//tools/build_defs/repo:utils.bzl", "patch")

_DEFAULT_TIMEOUT = 200  # seconds
_CLOUD_FILE_BUILD = """\
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "file",
    srcs = ["{}"],
)
"""

def validate_checksum(repo_ctx, url, local_path, expected_sha256):
    # Verify checksum
    if repo_ctx.os.name == "linux":
        sha256_cmd = [repo_ctx.which("sha256sum")]
    elif repo_ctx.os.name in ["mac os x", "darwin"]:
        sha256_cmd = [repo_ctx.which("shasum"), "-a", "256"]
    else:
        fail("Unsupported OS: " + repo_ctx.os.name)
    repo_ctx.report_progress("Checksumming {}.".format(local_path))
    sha256_result = repo_ctx.execute(sha256_cmd + [local_path])
    if sha256_result.return_code != 0:
        fail("Failed to verify checksum: {}".format(sha256_result.stderr))
    sha256 = sha256_result.stdout.split(" ")[0]
    if sha256 != expected_sha256:
        fail("Checksum mismatch for {}, expected {}, got {}.".format(
            url,
            expected_sha256,
            sha256,
        ))

def extract_archive(repo_ctx, local_path, strip_prefix, add_prefix, build_file, build_file_contents):
    bash_path = repo_ctx.os.environ.get("BAZEL_SH", "bash")
    if local_path.endswith(".tar.zst") or local_path.endswith(".tzst"):
        # Recent TAR supports zstd, if the compressor is installed.
        zst_path = repo_ctx.which("zstd")
        if zst_path == None:
            fail("To decompress .tar.zst, install zstd.")
        tar_path = repo_ctx.which("tar")
        if tar_path == None:
            fail("To decompress .tar.zst, install tar.")
        extra_tar_params = []
        if strip_prefix != None and strip_prefix:
            # Trick: we need to extract a subdir, and remove its components
            # from the path. We do so via `tar xvf file.tar.zst sub/dir
            # --strip-components=N`. Here we figure out the N.
            num_components = 0
            prefix = strip_prefix.strip("/")
            for c in prefix.split("/"):
                if len(c) > 0:
                    num_components += 1
            extra_tar_params = [prefix, "--strip-components=" + str(num_components)]
        if add_prefix:
            extra_tar_params += ["-C", add_prefix]
        # Decompress with tar, piping through zstd internally, and stripping prefix
        # if requested.
        tar_cmd = [tar_path, "-x", "-f", local_path] + extra_tar_params
        repo_ctx.execute(tar_cmd)
    else:
        # Extract the downloaded archive using Bazel's built-in decompressors.
        repo_ctx.extract(local_path, output = add_prefix, stripPrefix = strip_prefix)

    # Provide external BUILD file if requested; `build_file_contents` takes
    # priority.
    if build_file_contents:
        repo_ctx.execute([bash_path, "-c", "rm -f BUILD BUILD.bazel"])
        repo_ctx.file("BUILD.bazel", build_file_contents, executable = False)
    elif build_file:
        repo_ctx.execute([bash_path, "-c", "rm -f BUILD BUILD.bazel"])
        repo_ctx.symlink(build_file, "BUILD.bazel")

def cloud_file_download(
        repo_ctx,
        file_path,
        expected_sha256,
        provider,
        bucket = "",
        region = "",
        profile = "",
        file_version = "",
        downloaded_file_path = "downloaded",
        executable = False,
        timeout = _DEFAULT_TIMEOUT):
    """ Securely downloads a file from Minio, then places a BUILD file inside. """
    repo_root = repo_ctx.path(".")
    forbidden_files = [
        repo_root,
        repo_ctx.path("WORKSPACE"),
        repo_ctx.path("BUILD"),
        repo_ctx.path("BUILD.bazel"),
        repo_ctx.path("file/BUILD"),
        repo_ctx.path("file/BUILD.bazel"),
    ]
    download_path = repo_ctx.path("file/" + downloaded_file_path)
    if download_path in forbidden_files or not str(download_path).startswith(str(repo_root)):
        fail("'%s' cannot be used as file_path in http_file" % downloaded_file_path)

    # This has to be before the download otherwise some tools may fail to create the directory.
    repo_ctx.file("file/BUILD", _CLOUD_FILE_BUILD.format(downloaded_file_path))
    cloud_download(
        repo_ctx,
        file_path,
        expected_sha256,
        provider,
        bucket,
        region,
        profile,
        file_version,
        "file/" + downloaded_file_path,
        timeout,
    )
    if executable:
        repo_ctx.execute(["chmod", "+x", "file/" + downloaded_file_path])

def cloud_archive_download(
        repo_ctx,
        file_path,
        expected_sha256,
        provider,
        bucket = "",
        region = "",
        strip_prefix = "",
        add_prefix = "",
        type = "",
        build_file = "",
        build_file_contents = "",
        profile = "",
        file_version = "",
        timeout = _DEFAULT_TIMEOUT):
    """ Securely downloads and unpacks an archive from Minio, then places a
    BUILD file inside. """
    downloaded_file_path = file_path
    if type:
        valid_extensions = ["zip", "jar", "war", "aar", "tar", "tar.gz", "tgz", "tar.xz", "txz", "tar.zst", "tzst", "tar.bz2", "ar", "deb"]
        if type not in valid_extensions:
            fail("Invalid archive type: {}".format(type))
        downloaded_file_path = downloaded_file_path + "." + type
    filename = repo_ctx.path(downloaded_file_path).basename

    # Download
    cloud_download(
        repo_ctx,
        file_path,
        expected_sha256,
        provider,
        bucket,
        region,
        profile,
        file_version,
        downloaded_file_path,
        timeout,
    )

    # Extract
    extract_archive(repo_ctx, filename, strip_prefix, add_prefix, build_file, build_file_contents)

    # Patch
    patch(repo_ctx)

def cloud_download(
        repo_ctx,
        file_path,
        expected_sha256,
        provider,
        bucket = "",
        region = "",
        profile = "",
        file_version = "",
        downloaded_file_path = "",
        timeout = _DEFAULT_TIMEOUT):
    """ Securely downloads a file from Minio. """
    downloaded_file_path = downloaded_file_path or file_path

    # Download tooling is pretty similar, but commands are different. Note that
    # Minio does not support bucket per se. The path is expected to contain what
    # you'd normally feed into `mc`.
    if provider == "minio":
        tool_path = repo_ctx.which("mc")
        src_url = file_path
        cmd = [tool_path, "cp", "-q", src_url, downloaded_file_path]
    elif provider == "google":
        tool_path = repo_ctx.which("gsutil")
        src_url = "gs://{}/{}".format(bucket, file_path)
        cmd = [tool_path, "cp", src_url, downloaded_file_path]
    elif provider == "s3":
        tool_path = repo_ctx.path(Label("@awscli//:aws"))
        extra_flags = ["--profile", profile] if profile else []
        extra_flags = ["--region", region] if region else []
        bucket_arg = ["--bucket", bucket]
        file_arg = ["--key", file_path]
        file_version_arg = ["--version-id", file_version] if file_version else []
        sign_request_arg = []
        # Check if the environment variable is set to force no-sign-request.
        if repo_ctx.os.environ.get("BAZEL_NO_SIGN_REQUEST", "false").lower() == "true":
            sign_request_arg = ["--no-sign-request"]
        # Check if the client is authenticated and fallback to an unsigned request if not.
        elif tool_path != None and repo_ctx.execute([tool_path, "sts", "get-caller-identity"]).return_code != 0:
            sign_request_arg = ["--no-sign-request"]
        src_url = repo_ctx.path(file_path).basename
        cmd = [tool_path] + extra_flags + ["s3api", "get-object"] + bucket_arg + file_arg + file_version_arg + sign_request_arg + [downloaded_file_path]
    elif provider == "backblaze":
        # NOTE: currently untested, as I don't have a B2 account.
        tool_path = repo_ctx.which("b2")
        src_url = "b2://{}/{}".format(bucket, file_path)
        cmd = [tool_path, "download-file-by-name", "--noProgress", bucket, downloaded_file_path, "."]
    else:
        fail("Provider not supported: " + provider.capitalize())

    if tool_path == None:
        fail("Could not find command line utility for {}".format(provider.capitalize()))

    # Download.
    repo_ctx.report_progress("Downloading {}.".format(src_url))
    result = repo_ctx.execute(cmd, timeout = timeout)
    if result.return_code != 0:
        fail("Failed to download {} from {}: {}".format(src_url, provider.capitalize(), result.stderr))

    # Verify.
    validate_checksum(repo_ctx, file_path, downloaded_file_path, expected_sha256)

def _cloud_file_impl(ctx):
    """Implementation of the provider-agnostic, file-based rule."""
    cloud_file_download(
        ctx,
        ctx.attr.file_path,
        ctx.attr.sha256,
        provider = ctx.attr._provider,
        profile = ctx.attr.profile if hasattr(ctx.attr, "profile") else "",
        bucket = ctx.attr.bucket if hasattr(ctx.attr, "bucket") else "",
        region = ctx.attr.region if hasattr(ctx.attr, "region") else "",
        file_version = ctx.attr.file_version if hasattr(ctx.attr, "file_version") else "",
        downloaded_file_path = ctx.attr.downloaded_file_path,
        executable = ctx.attr.executable,
        timeout = ctx.attr.timeout,
    )

def _cloud_archive_impl(ctx):
    cloud_archive_download(
        ctx,
        ctx.attr.file_path,
        ctx.attr.sha256,
        provider = ctx.attr._provider,
        strip_prefix = ctx.attr.strip_prefix,
        add_prefix = ctx.attr.add_prefix,
        type = ctx.attr.type,
        build_file = ctx.attr.build_file,
        build_file_contents = ctx.attr.build_file_contents,
        profile = ctx.attr.profile if hasattr(ctx.attr, "profile") else "",
        bucket = ctx.attr.bucket if hasattr(ctx.attr, "bucket") else "",
        region = ctx.attr.region if hasattr(ctx.attr, "region") else "",
        file_version = ctx.attr.file_version if hasattr(ctx.attr, "file_version") else "",
        timeout = ctx.attr.timeout,
    )

minio_file = repository_rule(
    implementation = _cloud_file_impl,
    attrs = {
        "file_path": attr.string(
            mandatory = True,
            doc = "Path to the file on minio. Backend needs to be set up locally for this to work.",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "downloaded_file_path": attr.string(
            default = "downloaded",
            doc = "Path assigned to the file downloaded",
        ),
        "executable": attr.bool(doc="If the downloaded file should be made executable."),
        "_provider": attr.string(default = "minio"),
    },
)

minio_archive = repository_rule(
    implementation = _cloud_archive_impl,
    attrs = {
        "file_path": attr.string(
            mandatory = True,
            doc = "Path to the file on minio. Backend needs to be set up locally for this to work.",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "build_file": attr.label(
            allow_single_file = True,
            doc = "BUILD file for the unpacked archive",
        ),
        "build_file_contents": attr.string(doc = "The contents of the build file for the target"),
        "type": attr.string(
            doc = """The archive type of the downloaded file.

By default, the archive type is determined from the file extension of the
URL. If the file has no extension, you can explicitly specify one of the
following: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`, `"tar.gz"`, `"tgz"`,
`"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `"tar.bz2"`, `"ar"`, or `"deb"`.""",
        ),
        "patches": attr.label_list(doc = "Patches to apply, if any.", allow_files = True),
        "patch_args": attr.string_list(doc = "Arguments to use when applying patches."),
        "patch_cmds": attr.string_list(doc = "Sequence of Bash commands to be applied after patches are applied."),
        "strip_prefix": attr.string(doc = "Prefix to strip when archive is unpacked"),
        "add_prefix": attr.string(
            default = "",
            doc = """Destination directory relative to the repository directory.

The archive will be unpacked into this directory, after applying `strip_prefix`
(if any) to the file paths within the archive. For example, file
`foo-1.2.3/src/foo.h` will be unpacked to `bar/src/foo.h` if `add_prefix = "bar"`
and `strip_prefix = "foo-1.2.3"`.""",
        ),
        "_provider": attr.string(default = "minio"),
    },
)

s3_file = repository_rule(
    implementation = _cloud_file_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Bucket name"),
        "region": attr.string(default = "", doc = "Region of the bucket"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching file"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "downloaded_file_path": attr.string(
            default = "downloaded",
            doc = "Path assigned to the file downloaded",
        ),
        "executable": attr.bool(doc="If the downloaded file should be made executable."),
        "_provider": attr.string(default = "s3"),
    },
)

s3_archive = repository_rule(
    implementation = _cloud_archive_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Bucket name"),
        "region": attr.string(default = "", doc = "Region of the bucket"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching archive"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "profile": attr.string(doc = "Profile to use for authentication."),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "build_file": attr.label(
            allow_single_file = True,
            doc = "BUILD file for the unpacked archive",
        ),
        "build_file_contents": attr.string(doc = "The contents of the build file for the target"),
        "type": attr.string(
            doc = """The archive type of the downloaded file.

By default, the archive type is determined from the file extension of the
URL. If the file has no extension, you can explicitly specify one of the
following: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`, `"tar.gz"`, `"tgz"`,
`"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `"tar.bz2"`, `"ar"`, or `"deb"`.""",
        ),
        "patches": attr.label_list(doc = "Patches to apply, if any.", allow_files = True),
        "patch_args": attr.string_list(doc = "Arguments to use when applying patches."),
        "patch_cmds": attr.string_list(doc = "Sequence of Bash commands to be applied after patches are applied."),
        "strip_prefix": attr.string(doc = "Prefix to strip when archive is unpacked"),
        "add_prefix": attr.string(
            default = "",
            doc = """Destination directory relative to the repository directory.

The archive will be unpacked into this directory, after applying `strip_prefix`
(if any) to the file paths within the archive. For example, file
`foo-1.2.3/src/foo.h` will be unpacked to `bar/src/foo.h` if `add_prefix = "bar"`
and `strip_prefix = "foo-1.2.3"`.""",
        ),
        "file_version": attr.string(doc = "file version id of object if bucket is versioned"),
        "_provider": attr.string(default = "s3"),
    },
)

gs_file = repository_rule(
    implementation = _cloud_file_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Google Storage bucket name"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching file"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "downloaded_file_path": attr.string(
            default = "downloaded",
            doc = "Path assigned to the file downloaded",
        ),
        "executable": attr.bool(doc="If the downloaded file should be made executable."),
        "_provider": attr.string(default = "google"),
    },
)

gs_archive = repository_rule(
    implementation = _cloud_archive_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Google Storage bucket name"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching archive"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "build_file": attr.label(
            allow_single_file = True,
            doc = "BUILD file for the unpacked archive",
        ),
        "build_file_contents": attr.string(doc = "The contents of the build file for the target"),
        "type": attr.string(
            doc = """The archive type of the downloaded file.

By default, the archive type is determined from the file extension of the
URL. If the file has no extension, you can explicitly specify one of the
following: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`, `"tar.gz"`, `"tgz"`,
`"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `"tar.bz2"`, `"ar"`, or `"deb"`.""",
        ),
        "patches": attr.label_list(doc = "Patches to apply, if any.", allow_files = True),
        "patch_args": attr.string_list(doc = "Arguments to use when applying patches."),
        "patch_cmds": attr.string_list(doc = "Sequence of Bash commands to be applied after patches are applied."),
        "strip_prefix": attr.string(doc = "Prefix to strip when archive is unpacked"),
        "add_prefix": attr.string(
            default = "",
            doc = """Destination directory relative to the repository directory.

The archive will be unpacked into this directory, after applying `strip_prefix`
(if any) to the file paths within the archive. For example, file
`foo-1.2.3/src/foo.h` will be unpacked to `bar/src/foo.h` if `add_prefix = "bar"`
and `strip_prefix = "foo-1.2.3"`.""",
        ),
        "_provider": attr.string(default = "google"),
    },
)

b2_file = repository_rule(
    implementation = _cloud_file_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Backblaze B2 bucket name"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching file"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "downloaded_file_path": attr.string(
            default = "downloaded",
            doc = "Path assigned to the file downloaded",
        ),
        "executable": attr.bool(doc="If the downloaded file should be made executable."),
        "_provider": attr.string(default = "backblaze"),
    },
)

b2_archive = repository_rule(
    implementation = _cloud_archive_impl,
    attrs = {
        "bucket": attr.string(mandatory = True, doc = "Backblaze B2 bucket name"),
        "timeout": attr.int(default = _DEFAULT_TIMEOUT, doc = "Timeout fetching archive"),
        "file_path": attr.string(
            mandatory = True,
            doc = "Relative path to the archive file within the bucket",
        ),
        "sha256": attr.string(mandatory = True, doc = "SHA256 checksum of the archive"),
        "build_file": attr.label(
            allow_single_file = True,
            doc = "BUILD file for the unpacked archive",
        ),
        "build_file_contents": attr.string(doc = "The contents of the build file for the target"),
        "type": attr.string(
            doc = """The archive type of the downloaded file.

By default, the archive type is determined from the file extension of the
URL. If the file has no extension, you can explicitly specify one of the
following: `"zip"`, `"jar"`, `"war"`, `"aar"`, `"tar"`, `"tar.gz"`, `"tgz"`,
`"tar.xz"`, `"txz"`, `"tar.zst"`, `"tzst"`, `"tar.bz2"`, `"ar"`, or `"deb"`.""",
        ),
        "patches": attr.label_list(doc = "Patches to apply, if any.", allow_files = True),
        "patch_args": attr.string_list(doc = "Arguments to use when applying patches."),
        "patch_cmds": attr.string_list(doc = "Sequence of Bash commands to be applied after patches are applied."),
        "strip_prefix": attr.string(doc = "Prefix to strip when archive is unpacked"),
        "add_prefix": attr.string(
            default = "",
            doc = """Destination directory relative to the repository directory.

The archive will be unpacked into this directory, after applying `strip_prefix`
(if any) to the file paths within the archive. For example, file
`foo-1.2.3/src/foo.h` will be unpacked to `bar/src/foo.h` if `add_prefix = "bar"`
and `strip_prefix = "foo-1.2.3"`.""",
        ),
        "_provider": attr.string(default = "backblaze"),
    },
)
