# CtrlPanel.gg Installation Script

This script automates the full installation of [CtrlPanel.gg](https://ctrlpanel.gg), including Docker, Docker Compose, nginx configuration, SSL with Let's Encrypt, and CtrlPanel setup.

## Features

- Interactive prompt with sensible defaults
- Automated Docker & Compose setup
- Auto SSL certificate via Certbot
- Configures nginx reverse proxy
- Installs latest CtrlPanel.gg release

## Requirements

- A fresh Ubuntu 20.04 / 22.04 server
- A domain name pointing to your server's IP
- Root access (`sudo` or direct root)

## Usage

Run the following command on your server:

```bash<(curl -s https://raw.githubusercontent.com/SaturoTech1/ctrlpanel-installer/refs/heads/main/install_ctrlpanel.sh)
```

The script will ask for:

- Your domain (used for nginx and SSL)
- Your email (used for Let's Encrypt)
- Whether to proceed with default installation options

## Post Installation

Once the script completes:

- Visit `https://your-domain.com` in your browser
