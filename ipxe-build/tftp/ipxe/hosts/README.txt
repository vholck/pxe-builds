Per-device iPXE scripts. boot.ipxe chains ipxe/hosts/<mac>.ipxe before the default (IPXE_CHAIN_URI).

Name the file after the client's MAC address, lower-case, with hyphens:

    ipxe/hosts/02-00-00-00-00-02.ipxe

Files committed here are baked into the image and published on every deploy.
Files you put in <tftp root>/ipxe/hosts/ yourself are left alone.
