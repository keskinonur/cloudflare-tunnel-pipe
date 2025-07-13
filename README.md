# CFTPIPE Usage Documentation

`cftpipe.sh` is a command-line tool for managing Cloudflare Tunnels, allowing you to easily expose local web servers to the internet.

## Prerequisites

Before using this script, ensure you have the following tools installed:

*   `cloudflared`: The Cloudflare Tunnel daemon.
*   `jq`: A lightweight and flexible command-line JSON processor.
*   `curl`: A tool to transfer data from or to a server.
*   `openssl`: For generating random IDs.

## Environment Variables

The script requires the following environment variables to be set:

*   `CF_API_TOKEN`: Your Cloudflare API token with permissions to edit DNS and Cloudflare Tunnels.
*   `CF_ACCOUNT_ID` (optional): Your Cloudflare Account ID. If not set, the script will prompt you for it during setup.

You can export them in your shell configuration file (e.g., `~/.zshrc` or `~/.bashrc`):

```bash
export CF_API_TOKEN="your_cloudflare_api_token"
export CF_ACCOUNT_ID="your_cloudflare_account_id"
```

## Commands

The script supports the following commands:

### `setup`

Initializes the Cloudflare Tunnel configuration. This command only needs to be run once.

**Usage:**

```bash
./cftpipe.sh setup
```

This command will:
1.  Prompt you for your Cloudflare Account ID if not set via `CF_ACCOUNT_ID`.
2.  List your available domains (zones) and prompt you to select one.
3.  Create a new Cloudflare Tunnel.
4.  Save the tunnel configuration to `~/.cloudflared/tunnel-config.json`.

### `run`

Starts the Cloudflare Tunnel, exposing a local port to a public URL.

**Usage:**

```bash
./cftpipe.sh run [options]
```

**Options:**

*   `-p, --port <port>`: Specify the local port to expose. If not provided, the script will attempt to detect a running service on common development ports. Defaults to `3000` if none are detected.
*   `-s, --name <slug>`: Specify a custom subdomain (slug). If not provided, a unique slug will be generated (e.g., `myproject-123456-abcdef`).
*   `-r, --reuse`: Reuse the last known hostname for the current directory.

**Examples:**

*   **Autodetect port and generate a new hostname:**
    ```bash
    ./cftpipe.sh run
    ```
*   **Specify a port:**
    ```bash
    ./cftpipe.sh run -p 8080
    ```
    or
    ```bash
    ./cftpipe.sh run 8080
    ```
*   **Specify a custom hostname:**
    ```bash
    ./cftpipe.sh run -s my-cool-app
    ```
    This will create a tunnel at `my-cool-app.yourdomain.com`.
*   **Reuse the previous hostname for the project:**
    ```bash
    ./cftpipe.sh run -r
    ```

### `destroy`

Deletes the DNS record for a given slug.

**Usage:**

```bash
./cftpipe.sh destroy <slug>
```

**Example:**

```bash
./cftpipe.sh destroy my-cool-app
```

This will delete the CNAME record for `my-cool-app.yourdomain.com`. It will also ask if you want to delete the entire tunnel, which would affect all subdomains created with it.

### `list`

Lists the 20 most recently created tunnels from your history.

**Usage:**

```bash
./cftpipe.sh list
```

**Output format:**

```
<timestamp> | <project> | https://<hostname> | port <port>
```

### `status`

Displays the current tunnel configuration from `~/.cloudflared/tunnel-config.json`.

**Usage:**

```bash
./cftpipe.sh status
```

### `help`

Displays the help message.

**Usage:**

```bash
./cftpipe.sh help
```
or
```bash
./cftpipe.sh -h
```
or
```bash
./cftpipe.sh --help
```
