#!/bin/bash

# V2Ray Proxy Tester Manager
# اسکریپت مدیریت کامل سیستم تست پروکسی

WORK_DIR="$HOME/v2ray-tester"
LOG_FILE="$WORK_DIR/test.log"
PROXIES_FILE="$WORK_DIR/working_proxies.txt"

show_menu() {
    clear
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    V2Ray Proxy Tester                       ║"
    echo "║                      مدیریت سیستم                          ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║ 1. اجرای تست فوری                                          ║"
    echo "║ 2. مشاهده پروکسی‌های کارآمد                                 ║"
    echo "║ 3. مشاهده لاگ‌ها                                           ║"
    echo "║ 4. مشاهده وضعیت cron job                                   ║"
    echo "║ 5. فعال/غیرفعال کردن cron job                              ║"
    echo "║ 6. تنظیمات پیشرفته                                         ║"
    echo "║ 7. حذف سیستم                                               ║"
    echo "║ 0. خروج                                                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
}

run_test() {
    echo "شروع تست..."
    cd "$WORK_DIR"
    ./run_tester.sh
    echo ""
    echo "تست تکمیل شد. Enter برای ادامه..."
    read
}

show_working_proxies() {
    if [ ! -f "$PROXIES_FILE" ]; then
        echo "فایل پروکسی‌های کارآمد یافت نشد!"
        echo "ابتدا یک بار تست را اجرا کنید."
        echo ""
        echo "Enter برای ادامه..."
        read
        return
    fi
    
    echo "=== پروکسی‌های کارآمد ==="
    echo ""
    head -20 "$PROXIES_FILE"
    echo ""
    echo "=== آمار ==="
    proxy_count=$(grep -c "^vmess://" "$PROXIES_FILE" 2>/dev/null || echo "0")
    echo "تعداد پروکسی‌های کارآمد: $proxy_count"
    echo "آخرین بروزرسانی: $(head -1 "$PROXIES_FILE" | grep -o '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]')"
    echo ""
    echo "Enter برای ادامه..."
    read
}

show_logs() {
    if [ ! -f "$LOG_FILE" ]; then
        echo "فایل لاگ یافت نشد!"
        echo ""
        echo "Enter برای ادامه..."
        read
        return
    fi
    
    echo "=== آخرین لاگ‌ها ==="
    echo ""
    tail -50 "$LOG_FILE"
    echo ""
    echo "Enter برای ادامه..."
    read
}

show_cron_status() {
    echo "=== وضعیت Cron Job ==="
    echo ""
    
    cron_line=$(crontab -l 2>/dev/null | grep "v2ray-tester")
    if [ -n "$cron_line" ]; then
        echo "✓ Cron job فعال است:"
        echo "$cron_line"
        echo ""
        echo "این به معنای اجرای خودکار هر ۳ ساعت است."
        
        # آخرین زمان اجرا
        if [ -f "$LOG_FILE" ]; then
            echo ""
            echo "آخرین اجرا:"
            grep "===" "$LOG_FILE" | tail -1
        fi
    else
        echo "✗ Cron job فعال نیست!"
        echo ""
        echo "برای فعال‌سازی از گزینه ۵ استفاده کنید."
    fi
    
    echo ""
    echo "Enter برای ادامه..."
    read
}

toggle_cron() {
    cron_line=$(crontab -l 2>/dev/null | grep "v2ray-tester")
    
    if [ -n "$cron_line" ]; then
        echo "Cron job فعال است. آیا می‌خواهید غیرفعال کنید؟ (y/n)"
        read -n 1 answer
        echo ""
        
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            crontab -l 2>/dev/null | grep -v "v2ray-tester" | crontab -
            echo "Cron job غیرفعال شد."
        fi
    else
        echo "Cron job غیرفعال است. آیا می‌خواهید فعال کنید؟ (y/n)"
        read -n 1 answer
        echo ""
        
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            (crontab -l 2>/dev/null; echo "0 */3 * * * cd ~/v2ray-tester && ./run_tester.sh >> ~/v2ray-tester/test.log 2>&1") | crontab -
            echo "Cron job فعال شد. (هر ۳ ساعت اجرا می‌شود)"
        fi
    fi
    
    echo ""
    echo "Enter برای ادامه..."
    read
}

advanced_settings() {
    while true; do
        clear
        echo "=== تنظیمات پیشرفته ==="
        echo ""
        echo "1. تغییر زمان‌بندی cron job"
        echo "2. تغییر تعداد thread های تست"
        echo "3. تغییر timeout تست"
        echo "4. مشاهده فایل کانفیگ"
        echo "5. بروزرسانی لیست سرورها"
        echo "0. بازگشت"
        echo ""
        read -p "انتخاب شما: " choice
        
        case $choice in
            1)
                echo "زمان‌بندی‌های رایج:"
                echo "هر ساعت: 0 * * * *"
                echo "هر ۳ ساعت: 0 */3 * * *"
                echo "هر ۶ ساعت: 0 */6 * * *"
                echo "هر ۱۲ ساعت: 0 */12 * * *"
                echo "روزانه: 0 0 * * *"
                echo ""
                read -p "زمان‌بندی جدید را وارد کنید: " new_schedule
                
                if [ -n "$new_schedule" ]; then
                    crontab -l 2>/dev/null | grep -v "v2ray-tester" | crontab -
                    (crontab -l 2>/dev/null; echo "$new_schedule cd ~/v2ray-tester && ./run_tester.sh >> ~/v2ray-tester/test.log 2>&1") | crontab -
                    echo "زمان‌بندی به‌روزرسانی شد."
                fi
                ;;
            2)
                echo "تعداد thread های فعلی در فایل test_proxies.py قابل تغییر است."
                echo "خط max_workers=20 را ویرایش کنید."
                ;;
            3)
                echo "timeout فعلی در فایل test_proxies.py قابل تغییر است."
                echo "خط timeout=10 را ویرایش کنید."
                ;;
            4)
                echo "=== محتوای فایل کانفیگ ==="
                cat "$WORK_DIR/test_proxies.py" | head -30
                echo "..."
                ;;
            5)
                echo "لیست سرورها در فایل test_proxies.py قابل ویرایش است."
                echo "آرایه subscription_urls را ویرایش کنید."
                ;;
            0)
                break
                ;;
            *)
                echo "گزینه نامعتبر!"
                ;;
        esac
        
        echo ""
        echo "Enter برای ادامه..."
        read
    done
}

uninstall() {
    echo "آیا مطمئن هستید که می‌خواهید سیستم را حذف کنید؟ (y/n)"
    read -n 1 answer
    echo ""
    
    if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
        echo "حذف cron job..."
        crontab -l 2>/dev/null | grep -v "v2ray-tester" | crontab -
        
        echo "حذف فایل‌ها..."
        rm -rf "$WORK_DIR"
        
        echo "سیستم با موفقیت حذف شد."
        exit 0
    else
        echo "عملیات لغو شد."
    fi
    
    echo ""
    echo "Enter برای ادامه..."
    read
}

# بررسی وجود دایرکتوری کاری
if [ ! -d "$WORK_DIR" ]; then
    echo "دایرکتوری کاری یافت نشد!"
    echo "ابتدا اسکریپت نصب را اجرا کنید."
    exit 1
fi

# حلقه اصلی منو
while true; do
    show_menu
    read -p "انتخاب شما: " choice
    
    case $choice in
        1)
            run_test
            ;;
        2)
            show_working_proxies
            ;;
        3)
            show_logs
            ;;
        4)
            show_cron_status
            ;;
        5)
            toggle_cron
            ;;
        6)
            advanced_settings
            ;;
        7)
            uninstall
            ;;
        0)
            echo "خروج از سیستم."
            exit 0
            ;;
        *)
            echo "گزینه نامعتبر!"
            echo "Enter برای ادامه..."
            read
            ;;
    esac
done
