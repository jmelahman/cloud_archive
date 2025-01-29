"""Runtime dependencies for the cloud_archive rules."""

load("@bazel_tools//tools/build_defs/repo:http.bzl", _http_archive = "http_archive")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")

def http_archive(**kwargs):
    maybe(_http_archive, **kwargs)

def awscli_deps(version = "2.23.8", sha256 = "dc9ab7c6a29f61a458d592b41f01524b57f8fa79c7385cb87f8ed8ee8954e64f"):
    http_archive(
        name = "awscli",
        sha256 = sha256,
        strip_prefix = "aws/dist/",
        urls = [
            "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-{version}.zip".format(version = version),
        ],
    )
