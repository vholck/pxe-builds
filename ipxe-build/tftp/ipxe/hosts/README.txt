Per-device iPXE scripts. boot.ipxe chains ipxe/hosts/<mac>.ipxe before the stack default.

Name the file after the client's MAC address, lower-case, with hyphens:

    ipxe/hosts/02-00-00-00-00-02.ipxe

Files committed here are baked into the image and published on every deploy.
Files placed directly in <tftp root>/ipxe/hosts/ on the boot host are left alone.
