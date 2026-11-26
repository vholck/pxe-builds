# Tools for build-extra-initrd.sh (Pi 5 extra initrd for Fedora CoreOS releases);
# assemble.sh also uses its python3 to read the release list.
# Used by .github/workflows/build-coreos.yml and for builds by hand:
#   docker build -t coreos-build coreos-build
#   docker run --rm -v "$PWD/out:/out" coreos-build fedora-coreos 45.20261030.3.1 /out
FROM registry.fedoraproject.org/fedora:43

RUN dnf -q -y install cpio kmod rpm zstd findutils coreutils curl python3 && dnf clean all

COPY build-extra-initrd.sh /build-extra-initrd.sh

ENTRYPOINT ["/bin/bash", "/build-extra-initrd.sh"]
