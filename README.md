# ubtools

Personal productivity tools for Ubuntu.

## Quick Start

```bash
git clone https://github.com/amirilf/ubtools ~/.ubtools
cd ~/.ubtools
bash install.sh
source ~/.bashrc
```

`install.sh` lets you pick which tools to install, checks system dependencies, and adds the necessary lines to `~/.bashrc`.

---

## Tools

<details>
<summary><b>ath</b> — TOTP authenticator with encrypted vault</summary>

Manages TOTP secrets in an AES-256 encrypted file. A passphrase is required on every use — secrets are never stored in plain text.

**Dependencies**

```bash
sudo apt install oathtool fzf openssl
# clipboard (pick one):
sudo apt install xclip        # X11
sudo apt install wl-clipboard # Wayland
```

**Usage**

```bash
ath              # open fzf picker — navigate, Enter to copy code
ath add          # add a new entry (service, username, Base32 secret)
ath drop         # fzf picker to remove an entry
ath edit         # fzf picker to edit an entry
ath export path  # export an encrypted backup (separate passphrase)
ath import path  # import from an encrypted backup (handles duplicates)
ath passwd       # change your ath passphrase
```

**First run**

On the first invocation, `ath` creates the encrypted vault and asks you to set a passphrase. After that, every run asks for the passphrase to decrypt.

**Export / Import**

Export and import files are independently encrypted with a passphrase of your choice (can differ from your main ath passphrase). This lets you safely transfer entries between machines.

Import rules:
- Same service + username + secret → silently skipped
- Same service + username, different secret → warning, skipped
- New entry → added

</details>

---

<details>
<summary><b>bumper</b> — Maven version bumper</summary>

Interactively bumps the version in `pom.xml` and commits. Handles SNAPSHOT versions.

**Dependencies**

```bash
sudo apt install fzf
```

`git`, `awk` — standard on Ubuntu.

**Usage**

Run from a Maven project root:

```bash
bumper
```

Flow:
1. **Branch picker** — fzf list of local branches (current at top). Select another to switch first (requires clean working tree).
2. **Bump type** — choose major / minor / patch / none.
3. **Commit confirm** — commits `chore(pom): bump version to X.Y.Z`.

Supports `X.Y.Z` and `X.Y.Z-SNAPSHOT` version formats.

</details>

---

<details>
<summary><b>px</b> — GNOME proxy switcher</summary>

Switches the GNOME system proxy using an interactive fzf panel. Profiles are stored in a local config file.

**Dependencies**

```bash
sudo apt install fzf
```

`gsettings` — bundled with GNOME.

**Usage**

```bash
px           # open fzf picker — navigate profiles, Enter to activate
px add       # add a new proxy profile (name, http host:port, https, ignore list)
px drop      # fzf picker to remove a profile
px edit      # fzf picker to edit a profile
px off       # disable proxy immediately
px status    # show current proxy state
```

**Config format** (`~/.ubtools/proxy/.config`, created by `px add`):

```ini
[work]
http=192.168.1.1:8080
https=192.168.1.1:8080
ignore=localhost,127.0.0.1,::1
```

</details>

---

<details>
<summary><b>mvn</b> — Smart Maven wrapper</summary>

Overrides `mvn` with three automatic behaviors:

1. **Java auto-switch** — reads `java.version` / `maven.compiler.release` / `maven.compiler.target` from the nearest `pom.xml` and switches the active JDK via `update-java-alternatives`.
2. **Wrapper auto-generate** — if `mvnw` is absent but `pom.xml` exists, generates it from the latest Maven cached in `~/.m2/wrapper/dists`.
3. **Tab completion** — static completion for common goals and flags.

**Dependencies**

```bash
sudo apt install java-common curl
# Install the JDK versions your projects need:
sudo apt install openjdk-17-jdk openjdk-21-jdk
```

**Sourced, not executed** — handled automatically by `install.sh`. Do not run it directly.

**Usage**

Drop-in replacement for `mvn`:

```bash
mvn clean install
mvn spring-boot:run -DskipTests
mvn dependency:tree
```

Supported Java versions: 8, 11, 17, 21, 23.

</details>
