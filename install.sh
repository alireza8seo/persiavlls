#!/bin/bash

# V2Ray Proxy Tester - نصب و راه‌اندازی
# نسخه اصلاح‌شده با پشتیبانی از VLESS, Trojan, SS و رفع باگ‌ها

echo "=== نصب V2Ray Proxy Tester (نسخه اصلاح‌شده) ==="

# بروزرسانی سیستم
echo "بروزرسانی سیستم..."
sudo apt update && sudo apt upgrade -y

# نصب ابزارهای مورد نیاز
echo "نصب ابزارهای مورد نیاز (شامل curl, wget, jq, python3, pip, cron)..."
sudo apt install -y curl wget jq python3 python3-pip cron

# نصب وابستگی پایتون برای پشتیبانی از SOCKS
echo "نصب وابستگی SOCKS برای پایتون..."
pip3 install "requests[socks]"

# نصب V2Ray
echo "نصب V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# ساخت دایرکتوری کاری
mkdir -p ~/v2ray-tester
cd ~/v2ray-tester

# دانلود اسکریپت تست پروکسی (نسخه اصلاح شده)
cat > test_proxies.py << 'EOF'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import requests
import json
import base64
import urllib.parse
import subprocess
import time
import os
import sys
import tempfile
import signal
from concurrent.futures import ThreadPoolExecutor, as_completed

# --- کانفیگ‌های اصلی ---
SUBSCRIPTION_URLS = [
    "https://raw.githubusercontent.com/Kolandone/v2raycollector/main/config.txt",
    "https://raw.githubusercontent.com/SoliSpirit/v2ray-configs/refs/heads/main/all_configs.txt",
    "https://raw.githubusercontent.com/V2RayRoot/V2RayConfig/refs/heads/main/Config/shadowsocks.txt",
    "https://raw.githubusercontent.com/lagzian/SS-Collector/main/vmess.txt"
]
CONNECTION_TIMEOUT = 10  # ثانیه
MAX_WORKERS = 20         # تعداد تست‌های همزمان
TEST_URL = 'http://www.google.com' # استفاده از http برای جلوگیری از مشکلات SSL در تست
LOCAL_SOCKS_PORT = 1080

def fetch_proxy_lists(urls):
    """دریافت لیست پروکسی‌ها از URLهای مختلف"""
    all_proxies = []
    for url in urls:
        try:
            print(f"دریافت از: {url}")
            response = requests.get(url, timeout=30)
            response.raise_for_status()
            
            content = response.text
            try:
                if len(content) % 4 != 0:
                    content += '=' * (4 - len(content) % 4)
                decoded_content = base64.b64decode(content).decode('utf-8')
                proxies = decoded_content.strip().split('\n')
            except Exception:
                proxies = content.strip().split('\n')
            
            valid_proxies = [p.strip() for p in proxies if p.strip().startswith(('vmess://', 'vless://', 'trojan://', 'ss://'))]
            all_proxies.extend(valid_proxies)
            print(f"تعداد پروکسی دریافت شده: {len(valid_proxies)}")
        except Exception as e:
            print(f"خطا در دریافت {url}: {e}")
    
    unique_proxies = sorted(list(set(all_proxies)))
    print(f"تعداد کل پروکسی‌های یکتا: {len(unique_proxies)}")
    return unique_proxies

def parse_proxy_url(proxy_url):
    """تجزیه انواع URLهای پروکسی"""
    if proxy_url.startswith('vmess://'):
        return parse_vmess(proxy_url)
    elif proxy_url.startswith('vless://'):
        return parse_vless(proxy_url)
    elif proxy_url.startswith('trojan://'):
        return parse_trojan(proxy_url)
    elif proxy_url.startswith('ss://'):
        return parse_ss(proxy_url)
    return None

def parse_vmess(vmess_url):
    try:
        decoded_data = base64.b64decode(vmess_url[8:]).decode('utf-8')
        config = json.loads(decoded_data)
        return {
            "protocol": "vmess", "ps": config.get("ps"), "port": int(config.get("port")),
            "address": config.get("add"), "id": config.get("id"), "aid": config.get("aid", 0),
            "net": config.get("net"), "type": config.get("type"), "host": config.get("host"),
            "path": config.get("path"), "tls": config.get("tls")
        }
    except Exception: return None

def parse_vless(vless_url):
    try:
        parts = urllib.parse.urlparse(vless_url)
        params = urllib.parse.parse_qs(parts.query)
        return {
            "protocol": "vless", "ps": urllib.parse.unquote(parts.fragment) if parts.fragment else parts.netloc,
            "port": int(parts.port), "address": parts.hostname, "id": parts.username,
            "net": params.get("type", ["tcp"])[0], "security": params.get("security", ["none"])[0],
            "path": params.get("path", [""])[0], "host": params.get("host", [parts.hostname])[0],
            "sni": params.get("sni", [parts.hostname])[0]
        }
    except Exception: return None

def parse_trojan(trojan_url):
    try:
        parts = urllib.parse.urlparse(trojan_url)
        params = urllib.parse.parse_qs(parts.query)
        return {
            "protocol": "trojan", "ps": urllib.parse.unquote(parts.fragment) if parts.fragment else parts.netloc,
            "port": int(parts.port), "address": parts.hostname, "password": parts.username,
            "sni": params.get("sni", [parts.hostname])[0]
        }
    except Exception: return None

def parse_ss(ss_url):
    try:
        if '#' in ss_url:
            main_part, fragment = ss_url[5:].split('#', 1)
            ps = urllib.parse.unquote(fragment)
        else:
            main_part = ss_url[5:]
            ps = 'Unknown'

        if '@' in main_part:
            decoded_part = base64.b64decode(main_part.split('@')[0] + '==').decode('utf-8')
            method, password = decoded_part.split(':')
            address, port = main_part.split('@')[1].split(':')
        else:
            decoded_part = base64.b64decode(main_part + '==').decode('utf-8')
            method, password, address, port = decoded_part.replace('@', ':').split(':')
        
        return {
            "protocol": "shadowsocks", "ps": ps, "port": int(port),
            "address": address, "password": password, "method": method
        }
    except Exception: return None

def create_v2ray_config(proxy_config):
    """ساخت فایل کانفیگ V2Ray برای پروتکل‌های مختلف"""
    if not proxy_config: return None
    
    outbound = {"protocol": proxy_config["protocol"], "settings": {}, "streamSettings": {}}
    
    if proxy_config["protocol"] == "vmess":
        outbound["settings"]["vnext"] = [{"address": proxy_config["address"], "port": proxy_config["port"], "users": [{"id": proxy_config["id"], "alterId": proxy_config["aid"]}]}]
        outbound["streamSettings"]["network"] = proxy_config.get("net", "tcp")
        if proxy_config.get("net") == "ws":
            outbound["streamSettings"]["wsSettings"] = {"path": proxy_config.get("path", ""), "headers": {"Host": proxy_config.get("host", "")}}
        if proxy_config.get("tls") == "tls":
            outbound["streamSettings"]["security"] = "tls"
            outbound["streamSettings"]["tlsSettings"] = {"serverName": proxy_config.get("host", proxy_config["address"])}

    elif proxy_config["protocol"] == "vless":
        outbound["settings"]["vnext"] = [{"address": proxy_config["address"], "port": proxy_config["port"], "users": [{"id": proxy_config["id"], "flow": "xtls-rprx-direct"}]}]
        outbound["streamSettings"]["network"] = proxy_config.get("net", "tcp")
        if proxy_config.get("security") == "tls":
            outbound["streamSettings"]["security"] = "tls"
            outbound["streamSettings"]["tlsSettings"] = {"serverName": proxy_config.get("sni", proxy_config["address"])}
        if proxy_config.get("net") == "ws":
            outbound["streamSettings"]["wsSettings"] = {"path": proxy_config.get("path", ""), "headers": {"Host": proxy_config.get("host", "")}}
            
    elif proxy_config["protocol"] == "trojan":
        outbound["settings"]["servers"] = [{"address": proxy_config["address"], "port": proxy_config["port"], "password": proxy_config["password"]}]
        outbound["streamSettings"]["security"] = "tls"
        outbound["streamSettings"]["tlsSettings"] = {"serverName": proxy_config.get("sni", proxy_config["address"])}

    elif proxy_config["protocol"] == "shadowsocks":
        outbound["settings"]["servers"] = [{"address": proxy_config["address"], "port": proxy_config["port"], "password": proxy_config["password"], "method": proxy_config["method"]}]

    else:
        return None

    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"port": LOCAL_SOCKS_PORT, "listen": "127.0.0.1", "protocol": "socks", "settings": {"auth": "noauth", "udp": True}}],
        "outbounds": [outbound]
    }

def test_proxy_connection(proxy_url, timeout):
    """تست اتصال یک پروکسی"""
    proxy_config = parse_proxy_url(proxy_url)
    if not proxy_config:
        return False, "خطا در تجزیه URL", None

    v2ray_config = create_v2ray_config(proxy_config)
    if not v2ray_config:
        return False, f"ساخت کانفیگ برای پروتکل '{proxy_config.get('protocol')}' ناموفق بود", None

    tmp_config_file = None
    process = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', delete=False, suffix='.json') as f:
            json.dump(v2ray_config, f, indent=2)
            tmp_config_file = f.name

        cmd = ['v2ray', 'run', '-c', tmp_config_file]
        process = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, preexec_fn=os.setsid)
        time.sleep(2) # زمان برای بالا آمدن v2ray

        proxies = {
            'http': f'socks5h://127.0.0.1:{LOCAL_SOCKS_PORT}',
            'https': f'socks5h://127.0.0.1:{LOCAL_SOCKS_PORT}'
        }
        
        start_time = time.time()
        response = requests.get(TEST_URL, proxies=proxies, timeout=timeout)
        end_time = time.time()

        if response.status_code == 200:
            delay = round((end_time - start_time) * 1000)
            return True, f"تاخیر: {delay}ms", delay
        else:
            return False, f"کد وضعیت: {response.status_code}", None

    except requests.exceptions.RequestException as e:
        error_message = str(e)
        if "SOCKS" in error_message:
            return False, "خطای اتصال SOCKS", None
        elif "timed out" in error_message.lower():
            return False, "تایم اوت", None
        return False, "خطای اتصال", None
    except Exception as e:
        return False, f"خطای نامشخص: {e}", None
    finally:
        if process:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                process.wait(timeout=5)
            except (ProcessLookupError, PermissionError):
                pass
            except Exception:
                 os.killpg(os.getpgid(process.pid), signal.SIGKILL)
        if tmp_config_file and os.path.exists(tmp_config_file):
            os.remove(tmp_config_file)

def main():
    """اجرای تست کامل"""
    print("=== شروع تست پروکسی‌ها ===")
    
    proxy_list = fetch_proxy_lists(SUBSCRIPTION_URLS)
    if not proxy_list:
        print("هیچ پروکسی‌ای برای تست یافت نشد!")
        return

    print(f"\nشروع تست {len(proxy_list)} پروکسی با {MAX_WORKERS} ترد...")
    working_proxies = []
    
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        future_to_proxy = {executor.submit(test_proxy_connection, proxy, CONNECTION_TIMEOUT): proxy for proxy in proxy_list}
        
        for i, future in enumerate(as_completed(future_to_proxy)):
            proxy_url = future_to_proxy[future]
            ps_name = "نامشخص"
            try:
                parsed = parse_proxy_url(proxy_url)
                if parsed and parsed.get('ps'):
                    ps_name = parsed['ps']

                success, message, delay = future.result()
                
                status_symbol = "✓" if success else "✗"
                print(f"{status_symbol} [{i+1}/{len(proxy_list)}] {ps_name[:30]:<30} | {message}")

                if success:
                    working_proxies.append({'url': proxy_url, 'delay': delay, 'ps': ps_name})
            except Exception as e:
                print(f"✗ [{i+1}/{len(proxy_list)}] {ps_name[:30]:<30} | خطا در اجرای تست: {e}")

    working_proxies.sort(key=lambda x: x['delay'])
    
    # ذخیره نتایج
    output_filename = 'working_proxies.txt'
    with open(output_filename, 'w', encoding='utf-8') as f:
        f.write(f"# پروکسی‌های کارآمد - آخرین بروزرسانی: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
        f.write(f"# تعداد: {len(working_proxies)}\n\n")
        
        for proxy in working_proxies:
            f.write(f"# {proxy['ps']} (تاخیر: {proxy['delay']}ms)\n")
            f.write(f"{proxy['url']}\n\n")
    
    print(f"\n=== تست تکمیل شد ===")
    print(f"تعداد کل پروکسی‌های تست شده: {len(proxy_list)}")
    print(f"تعداد پروکسی‌های کارآمد: {len(working_proxies)}")
    print(f"نتایج در فایل {output_filename} ذخیره شد.")

    if working_proxies:
        best_proxy = working_proxies[0]
        print(f"🚀 بهترین پروکسی: {best_proxy['ps']} با تاخیر {best_proxy['delay']}ms")

if __name__ == "__main__":
    main()
EOF

# ساخت اسکریپت اصلی
cat > run_tester.sh << 'EOF'
#!/bin/bash

# V2Ray Proxy Tester - اسکریپت اصلی
cd ~/v2ray-tester

echo "=== $(date) ==="
echo "شروع تست پروکسی‌ها..."

# اجرای تست
python3 test_proxies.py

echo "تست تکمیل شد: $(date)"
echo "================================"
EOF

# اجازه اجرا
chmod +x test_proxies.py run_tester.sh

# نصب cron job برای اجرای هر ۳ ساعت
echo "راه‌اندازی cron job..."
(crontab -l 2>/dev/null | grep -v "v2ray-tester") | crontab -
(crontab -l 2>/dev/null; echo "0 */3 * * * cd ~/v2ray-tester && ./run_tester.sh >> ~/v2ray-tester/test.log 2>&1") | crontab -

echo "=== نصب با موفقیت تکمیل شد ==="
echo "اسکریپت شما اکنون از پروتکل‌های vmess, vless, trojan و shadowsocks پشتیبانی می‌کند."
echo ""
echo "فایل‌های ساخته شده:"
echo "- ~/v2ray-tester/test_proxies.py (اسکریپت اصلی پایتون)"
echo "- ~/v2ray-tester/run_tester.sh (اسکریپت اجرا)"
echo "- ~/v2ray-tester/test.log (فایل لاگ)"
echo "- ~/v2ray-tester/working_proxies.txt (پروکسی‌های کارآمد)"
echo ""
echo "برای اجرای دستی:"
echo "cd ~/v2ray-tester && ./run_tester.sh"
echo ""
echo "cron job به صورت خودکار هر ۳ ساعت یکبار اجرا خواهد شد."
