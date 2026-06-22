# Admin Password & Security Code Reset

[Back to README](../../README.en.md)

When you cannot log in to the console, or you forgot the security code used for high-sensitivity operations such as host-profile refresh and plaintext command-history viewing, reset the matching credential from your Baize installation directory. The reset only changes that credential; it does not wipe business data or regenerate the database, Redis, JWT, Agent communication, or credential master secrets.

> ⚠️ Do not reinitialize Baize just to recover a password or security code. Reinitialization changes multiple production secrets and can make old data, sessions, Agent communication, or encrypted credentials unusable.

## Before You Start

1. SSH into the server running Baize.
2. Enter the Baize public deployment directory, the one containing `.env`, `docker-compose.yml`, and `scripts/`.
3. Confirm Docker Compose is available:

```bash
docker compose version
```

If you are not sure you are in the right directory, run:

```bash
bash scripts/check-install.sh --offline
```

## Reset the Admin Password

Use this when you forgot the `admin` password, the account was locked by failed login attempts, or you cannot enter the console to change it there.

Interactive reset:

```bash
bash scripts/reset-admin-password.sh --username admin
```

The script asks for the new password twice. After it completes, log in to the console with the new password.

For unattended runs, pass the new password through an environment variable:

```bash
BAIZE_NEW_ADMIN_PASSWORD='<new-admin-password>' \
  bash scripts/reset-admin-password.sh --username admin --yes
```

Notes:

- The new password must be at least 8 characters; a password manager is recommended.
- The script only resets a local admin account and clears failed-login lock state.
- `ADMIN_PASSWORD` in `.env` is the initial value generated during first install. It is not updated after this reset and should not be treated as the current password source.
- Existing signed-in sessions may remain valid until they expire. If this is a security incident and all sessions must be invalidated immediately, back up first, rotate `JWT_SECRET` carefully, and recreate the control service; all users will need to sign in again.

## Reset the High-Sensitivity Operation Security Code

Use this when you forgot the security code for host-profile refresh, plaintext command-history viewing, and similar high-sensitivity operations. The code is separate from the login password and should be stored separately in your password manager.

Interactive reset:

```bash
bash scripts/reset-security-code.sh
```

The script asks for the new security code twice. It then stores a hash in `.env`, clears the plaintext value, and recreates the control service so the new code takes effect.

For unattended runs, pass the new code through an environment variable:

```bash
BAIZE_NEW_SECURITY_CODE='<new-security-code-at-least-24-chars>' \
  bash scripts/reset-security-code.sh --yes
```

Notes:

- The new security code must be at least 24 characters; a random string is recommended.
- After reset, `.env` stores `BAIZE_HOST_PROFILE_SECURITY_CODE_HASH`, and `BAIZE_HOST_PROFILE_SECURITY_CODE` is cleared.
- To update `.env` now and recreate the control service later, add `--no-restart`.
- Recreating the control service briefly interrupts console requests; PostgreSQL, Redis, and business data are not wiped.

## FAQ

**Can I use `scripts/reinit-config.sh` to recover a password?**

Not recommended. Reinitialization creates a fresh deployment configuration; it is not a credential recovery tool. Use the scripts on this page when you forgot a password or security code.

**Why can't I see the plaintext security code in `.env` after reset?**

That is expected. The reset script stores only a hash. The plaintext code exists only when you type it, so save the new code in your password manager.

**What if no resettable admin account is found?**

Confirm `--username` is a local account. The default initial account is `admin`. If you changed the admin username, check `ADMIN_USERNAME` in `.env` or contact support for help.

## Related Docs

- [Advanced Configuration](advanced.md)
- [Troubleshooting](troubleshooting.md)
- [Backup & Restore](backup-and-restore.md)
