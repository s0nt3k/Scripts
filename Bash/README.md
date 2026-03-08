# s0nt3k's Bash Shell Scripts

To run a Bash script directly from a GitHub URL in **Ubuntu**, you typically download it first and then execute it. This is the safest and most common approach.

---

## 1. Download the Script

Use `curl` or `wget` to download the script.

### Using `wget`

```bash
wget https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Bash/distrosetup.sh
```

### Using `curl`

```bash
curl -O https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Bash/distrosetup.sh
```

This saves the script in your current directory.

---

## 2. Make the Script Executable

Linux requires execution permission for scripts.

```bash
chmod +x distrosetup.sh
```

---

## 3. Run the Script

```bash
./distrosetup.sh
```

If the script requires administrator privileges:

```bash
sudo ./distrosetup.sh
```

---

## 4. (Optional but Recommended) Inspect the Script First

Before running any script downloaded from the internet, open it to check what it does.

```bash
nano distrosetup.sh
```

or

```bash
less distrosetup.sh
```

This helps avoid running harmful commands.

---

## 5. One-Line Method (Advanced)

You *can* run the script directly without saving it:

```bash
bash <(curl -s https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Bash/distrosetup.sh)
```

or

```bash
curl -s https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Bash/distrosetup.sh | bash
```

However, this method **runs the script immediately without inspection**, so only use it if you trust the source.

---

✅ **Summary**

Safest workflow:

```bash
wget https://raw.githubusercontent.com/s0nt3k/Scripts/refs/heads/main/Bash/distrosetup.sh
chmod +x distrosetup.sh
./distrosetup.sh
```

---

If you'd like, I can also show you a **cleaner “curl | bash” installer pattern** many open-source projects use (with verification and safety checks).
