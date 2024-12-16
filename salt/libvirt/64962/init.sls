python3_lief:
  pkg.installed:
    - name: securityonion-python3-lief

fix-salt-ldap:
  cmd.script:
    - source: salt://libvirt/64962/scripts/fix-salt-ldap.py
    - require:
      - pkg: python3_lief
    - onchanges:
      - pkg: python3_lief
