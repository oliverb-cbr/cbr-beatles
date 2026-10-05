# Admin SSH keys

Put admin public keys (one per line) in a file named `administrators_authorized_keys` in this folder. `provision.ps1` copies it to `C:\ProgramData\ssh\administrators_authorized_keys` on each machine so `fleet.ps1` can reach them.

Public keys only. Never commit a private key.
