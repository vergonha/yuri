# yuri ‎ . ݁⋆ ۶ৎ ݁˖ . ݁

a version manager for windows, made of powershell scripts

---

## 𐔌՞. .՞𐦯 the antivirus wins every time

at work i'm on windows, and the company antivirus scans every binary that runs. fnm and mise are binaries, and they run every time a terminal opens, so every new shell sat there waiting for the scan to finish.

so yuri is plain powershell 5.1, the one that already ships with windows. nothing compiled, nothing for the antivirus to stop and look at, and nothing running when a terminal opens. switching versions is global: change it in one terminal and every terminal sees it right away.

node and python are the tools for now, but the core doesn't know anything about either. a new tool is one provider file.

this is a fix for my own setup, not a product.

---

### .𖥔 ݁ ˖ requirements ──

- windows 10 1803 or later, for the built-in `curl.exe` and `tar.exe`
- local admin, once, for the setup
- direct internet access to nodejs.org and nuget.org, proxies aren't supported yet
- no group policy forcing the execution policy to `AllSigned` or `Restricted`, check with `Get-ExecutionPolicy -List`

---

### ⋆˙⟡ setup ──

⤿ from a normal (not elevated) powershell, in the cloned folder on a local disk

```
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

⤿ accept the uac prompt. the setup:

- sets the execution policy for your user to `RemoteSigned`, if it's stricter
- copies yuri to `C:\yuri` and gives your user write access to it
- adds `C:\yuri\bin` and `C:\yuri\current\node` to the machine PATH

⤿ open a **new** terminal

old ones keep the old PATH, so in them `yuri` isn't found and it looks like the setup failed. it didn't.

```
yuri use node
yuri doctor
```

to update, `git pull` and run `install.ps1` again. installed versions are kept.

---

### ‧₊˚✩ usage ──

| command                       | what it does                                     |
| ----------------------------- | ------------------------------------------------ |
| `yuri use node`               | latest lts, installs it if needed                |
| `yuri use node@22`            | newest installed 22.x, otherwise newest published |
| `yuri use`                    | reads `.node-version`, `.nvmrc` or `.python-version` |
| `yuri use python@3.12`        | newest installed 3.12.x, otherwise newest published |
| `yuri install node@22`        | newest published 22.x                            |
| `yuri list`                   | installed versions (`*` = active)                |
| `yuri ls-remote node@lts`     | versions available for download                  |
| `yuri current`                | active versions                                  |
| `yuri which node`             | path of `node.exe`                               |
| `yuri uninstall node@20.11.0` | removes an installed version                     |
| `yuri doctor`                 | checks PATH, permissions and old node installs   |

versions can be written as `22.23.2`, `22.23`, `22`, `latest`, `lts` or `lts/jod`.

---

### ᯤ𓂃 how it works ──

```
C:\yuri\
├── bin\              yuri.ps1, yuri.cmd                        (in PATH)
├── core\             tool-independent logic
├── providers\        node.ps1, the only node-specific code
├── installs\
│   └── node\
│       └── <version>\
├── current\
│   └── node          junction -> installs\node\<version>       (in PATH)
└── cache\            version index (1 hour), PATH backups
```

`yuri use` only repoints the `current\node` junction. no hook in `$PROFILE`, nothing runs when a terminal opens.

node comes from the official zip at https://nodejs.org/dist, checked against `SHASUMS256.txt`. npm comes with it, and global packages (`npm i -g`) go into the version's own folder, so every version has its own.

python comes from the python.org NuGet package (a full install, pip and venv included), checked against the SHA512 that nuget.org publishes. `python -m pip install` goes into the version's own folder. only `python.exe` is in PATH, not `Scripts`, so run tools as `python -m <tool>`. `latest` skips pre-releases.

> `YURI_HOME` is for testing only. it makes yuri keep installs in another folder, but the PATH still points to `C:\yuri\current\node`, so the `node` in your terminal doesn't change.

the self-check runs with:

```
powershell -ExecutionPolicy Bypass -File tests\selfcheck.ps1
```

---

### 𖦹₊ ⊹ adding a tool ──

create `providers\<tool>.ps1` that calls `Register-YuriProvider` with:

- `Name`, `Executable`
- `ListRemote`: returns objects with `Version`, `Lts`, `Date`
- `GetArtifact`: takes a version, returns `@{ Url; FileName; Sha256 }`
- optional: `BinSubdir`, `DefaultSpec`, `VersionFiles`, `SpecExamples`, `ResolveNamed`, `PostInstall`, `Doctor`

then run `install.ps1` again, so the new `current\<tool>` folder goes into the PATH.

---

### ᶻ 𝗓 𐰁 removing it ──

⤿ take `C:\yuri\bin` and every `C:\yuri\current\<tool>` out of the machine PATH. the old PATH is backed up in `C:\yuri\cache\` if you'd rather restore it

⤿ delete the folder from cmd, not with `Remove-Item`, which follows junctions

```
rmdir /s /q C:\yuri
```

⤿ if you want the old execution policy back

```
Set-ExecutionPolicy Undefined -Scope CurrentUser
```

---

### .ᐟ notes ──

windows only, and it's going to stay that way. only tested on powershell 5.1, i haven't checked powershell 7 (`pwsh`) yet.