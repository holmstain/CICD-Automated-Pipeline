# VPS deployment setup

## Requirements

- Ubuntu/Debian VPS with Docker Engine and the Compose plugin, Git, Nginx, Certbot, and `curl`.
- Public DNS A/AAAA records pointing at the VPS; firewall allows TCP 80/443.
- A public GitHub repository and its GHCR package set to **Public**. New GHCR packages default to private, so the first VPS pull will fail until visibility is changed.
- A dedicated deploy account with Docker access and passwordless permission to run `nginx -t` and `systemctl reload nginx`.

## One-time setup

1. Install Docker, Git, Nginx, Certbot and the Certbot Nginx plugin. Enable Docker and Nginx at boot.
2. Choose one absolute deployment path, for example `/home/ubuntu/project-name` or `/var/www/project-name`. Clone the repository there as the deploy account. Set the GitHub repository Actions variable `DEPLOY_PATH` to this exact path.
3. Give the deploy account Docker access to prevent `Docker daemon permission denied` errors:

   ```sh
   sudo usermod -aG docker $USER
   ```

   Then log out and back in (including ending the SSH session), or run `newgrp docker` in the current session. Verify with `docker ps` before continuing.

4. Create `$DEPLOY_PATH/.env.production`, owned by the deploy account with mode `0600`. Put application environment values there, one `KEY=value` per line. Do not commit this file.
5. Create the first active-port include before enabling the Nginx site:

   ```sh
   printf 'set $active_port 3001;\n' | tee "$DEPLOY_PATH/active-port.conf" >/dev/null
   ```

   `scripts/deploy.sh` also creates this file with the safe `3001` default when it is missing. Copy `nginx.conf` to `/etc/nginx/sites-available/REPOSITORY.conf`; replace `OWNER/REPOSITORY` in its `include` path with the same absolute `DEPLOY_PATH` value, pointing to `$DEPLOY_PATH/active-port.conf`. The Nginx `proxy_pass` uses this file's `active_port`, and the deployment script updates that same file from the checkout directory. This include belongs at the path used by `nginx.conf` inside `location`; do not put a raw `proxy_pass` directive in a general `/etc/nginx/conf.d/*.conf` include, which is commonly loaded at `http` scope. Enable the Nginx site, then validate and reload Nginx.
6. Add GitHub Actions secrets `VPS_HOST`, `VPS_USER`, and `VPS_SSH_KEY` (private OpenSSH key for the deploy account). Add the matching public key to the account's `authorized_keys`. The workflow checks out the triggering commit in `$DEPLOY_PATH` and runs `scripts/deploy.sh` from that directory; keep the Actions variable, checkout path, and Nginx include path identical.
7. Add narrowly scoped sudoers entries for `nginx -t` and `systemctl reload nginx`. The deploy account also needs to write `active-port.conf` and access Docker. Do not grant unrestricted SSH access to untrusted contributors; protect `main`.
8. Point `server_name` in Nginx config to the domain, then run `sudo certbot --nginx -d example.com`. Verify renewal with `sudo certbot renew --dry-run`.
9. Push to `main`. After the first GHCR publication, change the package visibility to Public in GitHub Packages, then rerun deployment.

The deployment workflow fetches the triggering commit from the public repository at `DEPLOY_PATH`, then invokes `scripts/deploy.sh IMAGE_URI IMAGE_TAG` from that directory. The script uses the VPS `.env.production`; application secrets never pass through GitHub Actions. Compose binds app slots to `127.0.0.1:3001` and `127.0.0.1:3002`; Nginx forwards to the selected port from `active-port.conf`.

## First deployment and operations

The active include starts at port 3001. The first successful deployment starts the other slot and switches traffic. Confirm `https://example.com/health`, then inspect `docker compose ps` and `docker compose logs` from the checkout directory.

Use `bash scripts/deploy.sh ghcr.io/OWNER/REPOSITORY COMMIT_SHA` for a manual redeploy. `HEALTH_TIMEOUT` and `DRAIN_SECONDS` may be set in the shell. Long-lived requests can outlast the drain interval; increase it to match the application's maximum request duration.
