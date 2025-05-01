# OpenVPN PQC Installer

**Post-Quantum Cryptography (PQC) ready OpenVPN server installer and management script.**  
This script automates the installation, configuration, and management of an OpenVPN server using the latest OpenSSL 3.5+ with built-in post-quantum cryptography support (Kyber, ML-DSA, SLH-DSA, etc).

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
git clone https://github.com/Funtiknub/openvpn-pqc-installer.git
chmod +x open-pqc-vpn.sh
./open-pqc-vpn.sh
```
4. **Follow the interactive prompts:**
   - Choose IP, port, protocol, DNS, PQC KEM and signature algorithms, etc.
   - The script will install all dependencies, build OpenSSL and OpenVPN, generate keys/certs, and configure the server.

5. **After installation:**
   - The script will generate the first client configuration file (e.g., `/root/Client1.ovpn`).
   - Transfer this file to your client device and import it into your OpenVPN client.

6. **Managing the server:**
   - Re-run the script to access the management menu:
     - Add new PQC clients
     - Revoke existing clients (with CRL)
     - Remove the entire installation

## Security Notes

- All cryptographic operations use OpenSSL 3.5+ with PQC algorithms.
- Certificates and keys are stored in `/etc/openvpn/pqc-ca/`.
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


