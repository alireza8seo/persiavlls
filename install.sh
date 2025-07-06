#!/bin/bash

# V2Ray Proxy Tester - نصب و راه‌اندازی
# این اسکریپت تمام ابزارهای لازم را نصب می‌کند

echo "=== نصب V2Ray Proxy Tester ==="

# بروزرسانی سیستم
echo "بروزرسانی سیستم..."
sudo apt update && sudo apt upgrade -y

# نصب ابزارهای مورد نیاز
echo "نصب ابزارهای مورد نیاز..."
sudo apt install -y curl wget jq python3 python3-pip cron

# نصب V2Ray
echo "نصب V2Ray..."
bash <(curl -L https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh)

# ساخت دایرکتوری کاری
mkdir -p ~/v2ray-tester
cd ~/v2ray-tester

# دانلود اسکریپت تست پروکسی
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
from concurrent.futures import ThreadPoolExecutor, as_completed
import tempfile
import signal

class V2RayTester:
    def __init__(self):
        self.subscription_urls = [
            "https://raw.githubusercontent.com/Kolandone/v2raycollector/main/config.txt",
            "https://raw.githubusercontent.com/SoliSpirit/v2ray-configs/refs/heads/main/all_configs.txt",
            "https://raw.githubusercontent.com/V2RayRoot/V2RayConfig/refs/heads/main/Config/shadowsocks.txt",
            "https://raw.githubusercontent.com/lagzian/SS-Collector/main/vmess.txt"
        ]
        self.working_proxies = []
        self.v2ray_process = None
        self.temp_config_file = None
        
    def fetch_proxy_lists(self):
        """دریافت لیست پروکسی‌ها از URLهای مختلف"""
        all_proxies = []
        
        for url in self.subscription_urls:
            try:
                print(f"دریافت از: {url}")
                response = requests.get(url, timeout=30)
                response.raise_for_status()
                
                # تلاش برای decode کردن base64
                try:
                    decoded_content = base64.b64decode(response.text).decode('utf-8')
                    proxies = decoded_content.strip().split('\n')
                except:
                    # اگر base64 نبود، مستقیم استفاده کن
                    proxies = response.text.strip().split('\n')
                
                # فیلتر کردن لینک‌های خالی و نامعتبر
                valid_proxies = []
                for proxy in proxies:
                    proxy = proxy.strip()
                    if proxy and (proxy.startswith('vmess://') or 
                                proxy.startswith('vless://') or 
                                proxy.startswith('trojan://') or 
                                proxy.startswith('ss://')):
                        valid_proxies.append(proxy)
                
                all_proxies.extend(valid_proxies)
                print(f"تعداد پروکسی دریافت شده: {len(valid_proxies)}")
                
            except Exception as e:
                print(f"خطا در دریافت {url}: {e}")
        
        # حذف تکراری‌ها
        unique_proxies = list(set(all_proxies))
        print(f"تعداد کل پروکسی‌های یکتا: {len(unique_proxies)}")
        return unique_proxies
    
    def parse_vmess(self, vmess_url):
        """تجزیه VMess URL"""
        try:
            if not vmess_url.startswith('vmess://'):
                return None
            
            encoded_data = vmess_url[8:]  # حذف vmess://
            decoded_data = base64.b64decode(encoded_data).decode('utf-8')
            vmess_data = json.loads(decoded_data)
            
            return {
                "protocol": "vmess",
                "address": vmess_data.get("add"),
                "port": int(vmess_data.get("port", 0)),
                "id": vmess_data.get("id"),
                "aid": int(vmess_data.get("aid", 0)),
                "net": vmess_data.get("net", "tcp"),
                "type": vmess_data.get("type", "none"),
                "host": vmess_data.get("host", ""),
                "path": vmess_data.get("path", ""),
                "tls": vmess_data.get("tls", ""),
                "ps": vmess_data.get("ps", "")
            }
        except Exception as e:
            print(f"خطا در تجزیه VMess: {e}")
            return None
    
    def create_v2ray_config(self, proxy_config):
        """ساخت فایل کانفیگ V2Ray"""
        if proxy_config["protocol"] == "vmess":
            outbound = {
                "protocol": "vmess",
                "settings": {
                    "vnext": [{
                        "address": proxy_config["address"],
                        "port": proxy_config["port"],
                        "users": [{
                            "id": proxy_config["id"],
                            "aid": proxy_config["aid"]
                        }]
                    }]
                },
                "streamSettings": {
                    "network": proxy_config["net"]
                }
            }
            
            # اضافه کردن تنظیمات شبکه
            if proxy_config["net"] == "ws":
                outbound["streamSettings"]["wsSettings"] = {
                    "path": proxy_config["path"],
                    "headers": {"Host": proxy_config["host"]} if proxy_config["host"] else {}
                }
            elif proxy_config["net"] == "h2":
                outbound["streamSettings"]["httpSettings"] = {
                    "path": proxy_config["path"],
                    "host": [proxy_config["host"]] if proxy_config["host"] else []
                }
            
            # تنظیمات TLS
            if proxy_config["tls"] == "tls":
                outbound["streamSettings"]["security"] = "tls"
                outbound["streamSettings"]["tlsSettings"] = {
                    "serverName": proxy_config["host"] if proxy_config["host"] else proxy_config["address"]
                }
        else:
            return None
        
        config = {
            "log": {"loglevel": "warning"},
            "inbounds": [{
                "port": 1080,
                "protocol": "socks",
                "settings": {"udp": True}
            }],
            "outbounds": [outbound, {"protocol": "freedom", "tag": "direct"}],
            "routing": {
                "rules": [{
                    "type": "field",
                    "outboundTag": "direct",
                    "domain": ["geosite:private"]
                }]
            }
        }
        
        return config
    
    def test_proxy_connection(self, proxy_url, timeout=10):
        """تست اتصال یک پروکسی"""
        try:
            # تجزیه URL پروکسی
            if proxy_url.startswith('vmess://'):
                proxy_config = self.parse_vmess(proxy_url)
                if not proxy_config:
                    return False, "خطا در تجزیه VMess", None
            else:
                return False, "پروتکل پشتیبانی نمی‌شود", None
            
            # ساخت فایل کانفیگ
            v2ray_config = self.create_v2ray_config(proxy_config)
            if not v2ray_config:
                return False, "خطا در ساخت کانفیگ", None
            
            # نوشتن کانفیگ در فایل موقت
            with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
                json.dump(v2ray_config, f, indent=2)
                config_file = f.name
            
            try:
                # راه‌اندازی V2Ray
                process = subprocess.Popen(
                    ['v2ray', 'run', '-c', config_file],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    preexec_fn=os.setsid
                )
                
                # انتظار برای راه‌اندازی
                time.sleep(2)
                
                # تست اتصال
                start_time = time.time()
                test_response = requests.get(
                    'https://www.google.com',
                    proxies={'http': 'socks5://127.0.0.1:1080', 'https': 'socks5://127.0.0.1:1080'},
                    timeout=timeout
                )
                end_time = time.time()
                
                if test_response.status_code == 200:
                    delay = round((end_time - start_time) * 1000, 2)  # به میلی‌ثانیه
                    return True, f"تاخیر: {delay}ms", delay
                else:
                    return False, f"کد خطا: {test_response.status_code}", None
                    
            finally:
                # بستن پروسه V2Ray
                try:
                    os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                    process.wait(timeout=5)
                except:
                    try:
                        os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                    except:
                        pass
                
                # حذف فایل کانفیگ موقت
                try:
                    os.unlink(config_file)
                except:
                    pass
                    
        except Exception as e:
            return False, f"خطا: {str(e)}", None
    
    def test_proxies_parallel(self, proxy_list, max_workers=20):
        """تست موازی پروکسی‌ها"""
        print(f"شروع تست {len(proxy_list)} پروکسی با {max_workers} thread...")
        
        working_proxies = []
        
        with ThreadPoolExecutor(max_workers=max_workers) as executor:
            # ارسال تسک‌ها
            future_to_proxy = {
                executor.submit(self.test_proxy_connection, proxy): proxy 
                for proxy in proxy_list
            }
            
            # دریافت نتایج
            for i, future in enumerate(as_completed(future_to_proxy)):
                proxy = future_to_proxy[future]
                try:
                    success, message, delay = future.result()
                    if success:
                        working_proxies.append({
                            'url': proxy,
                            'delay': delay,
                            'message': message
                        })
                        print(f"✓ [{i+1}/{len(proxy_list)}] کارکرد: {message}")
                    else:
                        print(f"✗ [{i+1}/{len(proxy_list)}] ناکارآمد: {message}")
                except Exception as e:
                    print(f"✗ [{i+1}/{len(proxy_list)}] خطا: {e}")
        
        # مرتب‌سازی بر اساس تاخیر
        working_proxies.sort(key=lambda x: x['delay'])
        return working_proxies
    
    def save_working_proxies(self, working_proxies, filename='working_proxies.txt'):
        """ذخیره پروکسی‌های کارآمد"""
        with open(filename, 'w', encoding='utf-8') as f:
            f.write(f"# پروکسی‌های کارآمد - آخرین بروزرسانی: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"# تعداد: {len(working_proxies)}\n\n")
            
            for proxy in working_proxies:
                f.write(f"# تاخیر: {proxy['delay']}ms\n")
                f.write(f"{proxy['url']}\n\n")
        
        print(f"پروکسی‌های کارآمد در {filename} ذخیره شدند")
    
    def run_test(self):
        """اجرای تست کامل"""
        print("=== شروع تست پروکسی‌ها ===")
        
        # دریافت لیست پروکسی‌ها
        proxy_list = self.fetch_proxy_lists()
        if not proxy_list:
            print("هیچ پروکسی‌ای یافت نشد!")
            return
        
        # تست پروکسی‌ها
        working_proxies = self.test_proxies_parallel(proxy_list)
        
        # ذخیره نتایج
        self.save_working_proxies(working_proxies)
        
        print(f"=== تست تکمیل شد ===")
        print(f"تعداد کل پروکسی‌ها: {len(proxy_list)}")
        print(f"تعداد پروکسی‌های کارآمد: {len(working_proxies)}")
        
        if working_proxies:
            best_proxy = working_proxies[0]
            print(f"بهترین پروکسی: {best_proxy['delay']}ms")

if __name__ == "__main__":
    tester = V2RayTester()
    tester.run_test()
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
(crontab -l 2>/dev/null; echo "0 */3 * * * cd ~/v2ray-tester && ./run_tester.sh >> ~/v2ray-tester/test.log 2>&1") | crontab -

echo "=== نصب تکمیل شد ==="
echo "فایل‌های ساخته شده:"
echo "- ~/v2ray-tester/test_proxies.py (اسکریپت اصلی)"
echo "- ~/v2ray-tester/run_tester.sh (اسکریپت اجرا)"
echo "- ~/v2ray-tester/test.log (فایل لاگ)"
echo "- ~/v2ray-tester/working_proxies.txt (پروکسی‌های کارآمد)"
echo ""
echo "برای اجرای دستی:"
echo "cd ~/v2ray-tester && ./run_tester.sh"
echo ""
echo "cron job هر ۳ ساعت اجرا می‌شود"
