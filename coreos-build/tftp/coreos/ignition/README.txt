Ignition configs for Fedora CoreOS booted by ipxe/fcos.ipxe.

  <mac>.ign     for one machine; MAC lower-case with hyphens, e.g. 02-00-00-00-00-01.ign
  default.ign   for every machine without its own file

Without either file the live system starts without a config. The files must be
Ignition JSON (spec 3.x); write them in Butane and convert with "butane".
They are yours: the coreos-stage never changes or deletes files in this
directory other than this README.
