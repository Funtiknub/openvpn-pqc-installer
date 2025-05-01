# OpenVPN PQC Installer

**Post-Quantum Cryptography (PQC) ready OpenVPN server installer and management script.**  
This script automates the installation, configuration, and management of an OpenVPN server using the latest OpenSSL 3.5+ with built-in post-quantum cryptography support (Kyber, ML-DSA, SLH-DSA, etc).

> At the moment, this solution is among the most advanced and secure ways to deploy an OpenVPN server with post-quantum cryptography support.
> To our knowledge, there are currently no other open-source projects on GitHub that provide a ready-to-use installer and management script for a PQC-enabled OpenVPN server.
> This project was created to fill that gap and to help the community prepare for the post-quantum era.

## Features

- Automated installation of OpenSSL 3.5+ (with PQC support) and OpenVPN from source
- Generation of PQC-ready CA, server, and client certificates
- Support for hybrid and pure PQC KEMs (Kyber, X25519+Kyber, etc)
- Support for PQC signature algorithms (ML-DSA, SLH-DSA)
- Interactive configuration (port, protocol, DNS, cipher, PQC algorithms, etc)
- Automatic firewall and routing setup
- Easy client config generation and revocation (with CRL support)
- Systemd integration for OpenVPN service
- Colorful logging and error handling

## Requirements

- Linux server (Debian/Ubuntu, CentOS/RHEL, Arch supported)
- Root privileges
- Internet connection

## Quick Start

```bash
wget https://raw.githubusercontent.com/Funtiknub/openvpn-pqc-installer/main/open-pqc-vpn.sh
chmod +x open-pqc-vpn.sh
./open-pqc-vpn.sh
```
**Follow the interactive prompts:**
   - Choose IP, port, protocol, DNS, PQC KEM and signature algorithms, etc.
   - The script will install all dependencies, build OpenSSL and OpenVPN, generate keys/certs, and configure the server.

**After installation:**
   - The script will generate the first client configuration file (e.g., `/root/Client1.ovpn`).
   - Transfer this file to your client device and import it into your OpenVPN client.

**Managing the server:**
   - Re-run the script to access the management menu:
     - On subsequent runs, the script will display a simple interactive menu allowing you to:
       - Add new PQC clients
       - Revoke existing clients
       - Remove the entire installation
       - Exit

## Client Application for Windows

The 'Releases' section contains the installation files and instructions for the Windows client application. Download the latest release to get the PQC-enabled OpenVPN client and usage guide.

## Security Notes

- All cryptographic operations use OpenSSL 3.5+ with PQC algorithms.
- Certificates and keys are stored in `/etc/openvpn/pqc-ca/`. Client configuration files are also copied to `/root/client/` for convenience.
- Revoked clients are managed via a Certificate Revocation List (CRL).
- The script does not enable compression by default (to avoid VORACLE attack).

## Troubleshooting

- If you encounter issues, check the logs in `/var/log/pqc-vpn/`.
- For OpenVPN service status:  
  `systemctl status openvpn-server@server.service`
- For detailed logs:  
  `journalctl -xeu openvpn-server@server.service`

## Donations

If you want to support further development (and coffee!), you can donate via [cryptocurrency](./crypto-donations.md). Thank you! Have a nice day!

## License

MIT License

## Disclaimer

This script is provided as-is, without warranty. Use at your own risk.  
Post-quantum cryptography is an evolving field; for production use, always follow the latest recommendations from OpenSSL and OpenVPN projects.

## Acknowledgments

Special thanks to the teams at [www.openssl.org](https://www.openssl.org) and [community.openvpn.net](https://community.openvpn.net) for their continuous development and dedication. Your work makes secure and innovative solutions like this possible. Thank you for your commitment to open-source and cryptographic progress!


