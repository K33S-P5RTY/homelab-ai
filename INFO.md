# Homelab AI Stack
#### A zero-frills AI stack for developers who'd rather automate than empathize. 

This is a Bash script that takes a fresh Ubuntu 24.04 LTS machine and turns it into a hardened private AI server. It is fully automated. You do nothing. We maximize output by minimizing your effort.

## Why?
_ Cloud costs money 
_ You're sitting right there  
_ Cloud is someone else's computer  
_ GDPR can't violate you if you don't upload  
_ Why not?  


##  What you get

| Component | Why It Matters | Effort Saved |
|-----------------|----------------------------------------|--------------|
| **Ollama**      | Local LLMs that won't judge your queries | 3h of runtime debugging |
| **OpenWebUI**   | Fancy buttons so you feel productive   | 2 CSS frameworks avoided |
| **Docker**      | Because `apt install` is too reliable  | 1 existential crisis |
| **Self-signed TLS** | Browser screams but still works      | $0 SSL cert budget |


## What it does
Manually configured this so you never have to read a wiki again.

*   **Ollama**: The LLM engine.
*   **OpenWebUI**: The ChatGPT clone that runs locally.
*   **AgentZero**: Autonomous agents.
*   **Docker**: Because installing dependencies manually is a waste of life.
*   **Nginx**: Reverse proxy with wildcard self-signed certs. Security handled.
*   **UFW**: Firewall locked to LAN only. The outside world is denied.
*   **systemd-resolved**: Uses Quad9 DoT. Encrypted DNS. Your ISP sees nothing.

---

## Requirements (The bare minimum)
*   Ubuntu 24.04 LTS (Clean install is best, less friction)
*   Root/Sudo access (Obvious)
*   ≥8 GB RAM (If you have less, don't bother with AI)
*   ≥50 GB free disk (Script yells at you if space is low)
*   Internet connection (Only needed for the first run to download containers)

## Execution
Copy the command, paste it, go back to sleep.


## One‑liner installation
### Download
curl -O https://raw.githubusercontent.com/K33S-P5RTY/homelab-ai/main/homelab.sh

### Make executable
chmod +x homelab.sh

### Run
sudo ./homelab.sh

### After finish → reboot
sudo reboot

The script is **idempotent** – you can re‑run it any time. It will detect what is already installed and skip those steps.

---  

## FAQ / common gotchas  

**Q: My VM uses a NAT network, can I still use a static IP?**  
A: Yes. Use the NAT’s host‑only subnet (e.g., `192.168.56.0/24`). The script will still perform the ARP collision check, which just confirms the address isn’t used on the host‑only bridge.

**Q: I want TLS from a real CA instead of the self‑signed cert.**  
A: Replace `/etc/nginx/ssl/ai.crt` and `/etc/nginx/ssl/ai.key` with your own files and run `sudo systemctl reload nginx`. The rest of the stack does not care.

**Q: My LAN is 10.0.0.0/8, not 192.168.x.x.**  
A: Set `CIDR=8` and `STATIC_IP=10.0.0.42` (or any free address). The script will honour it.

**Q: Docker containers keep restarting – “OOMKilled”.**  
A: You hit the RAM limit. Either add swap (`sudo fallocate -l 4G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`) **or** increase the host RAM.

**Q: I need to expose the AI services to the internet securely.**  
A: This script is optimized for LAN‑only use. If you must expose them, put a proper reverse‑proxy (Cloudflare Tunnel, Tailscale Funnel, or a hardened VPN) in front of Nginx. Do **not** open the ports directly to the world.

  

**That’s it.** Run the script, walk away, and let your home AI stack stay up with minimal babysitting.  
