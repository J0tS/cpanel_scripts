#!/bin/bash
# Apache/PHP-FPM tuner for cPanel EasyApache 4
# tested under cPanel 11.84 and Apache 2.4

#set -x
#######################
# START settings
#######################

## php-fpm
tune_phpfpm="1"
def_phpfpm_avg_mem="10000"  # kilobytes
def_phpfpm_max_child="50"
def_phpfpm_max_req="200"
convert_all_to_fpm="0"

## apache
tune_apache="1"
def_apache_avg_mem="10000"  # kilobytes

## general
memory_preserve="0"         # megabytes, 20% of all available memory + 500M will be preserved if set to '0'
#######################
# END settings
#######################



#######################
# START function definitions
#######################
print_help() {
    cat <<EOF
ABOUT:
This script can be used to tune Apache and PHP-FPM under cPanel EasyApache 3/4.
If PHP-FPM is not enabled, script will enable it.

OPTIONS:
    -a|--auto-apply                     Apply changes immediately, without interactive prompts

    -A|--apache-only                    Skip PHP-FPM tuning
    -W|--apache-maxworkers [number]     Override Apache MaxRequestWorkers value
    -M|--apache-mpm [worker/event/prefork]
                                        Change MPM module for Apache. Applied regardless if apache tuning is enabled. [ default: no ]

    -f|--fpm-only                       Skip Apache tuning
    -c|--phpfpm-maxchildren [number]    Override PHP-FPM max_chilren value
    -r|--phpfpm-maxrequests [number]    Override PHP-FPM max_requests value
    -C|--convert                        Convert all accounts to PHP-FPM after setup. Applied regardless if php-fpm tuning is enabled [ default: no ]

    -h|--help|-?                        Show this text and exit
    -p|--preserve-mem X                 Preserve X megabytes of memory when tuning (static value vs default: 20% of max + 500M)
EOF
}


parse_input() {
    while (( "$#" )); do
        case $1 in
            -a|--auto-apply)
                auto_apply="1"
                shift
                ;;
            -A|--apache-only)
                tune_phpfpm="0"
                shift
                ;;
            -W|--apache-maxworkers)
                apache_optimal="$2"
                shift 2
                ;;
            -M|--apache-mpm)
                change_mpm=1
                case $2 in
                    event)
                        new_mpm="ea-apache24-mod_mpm_event"
                        ;;
                    worker)
                        new_mpm="ea-apache24-mod_mpm_worker"
                        ;;
                    prefork)
                        new_mpm="ea-apache24-mod_mpm_prefork"
                        ;;
                esac
                shift 2
                ;;
            -f|--fpm-only)
                tune_apache="0"
                shift 0
                ;;
            -c|--phpfpm-maxchildren)
                phpfpm_max_child="$2"
                shift 2
                ;;
            -r|--phpfpm-maxrequests)
                phpfpm_max_req="$2"
                shift 2
                ;;
            -C|--convert)
                convert_all_to_fpm="1"
                shift
                ;;
            -h|--help|-?)
                print_help
                exit 0
                ;;
            -p|--preserve-mem)
                memory_preserve="$2"
                shift 2
                ;;
            *)
                echo "ERROR: unrecognized option '$1'. Aborting"
                print_help
                exit 1
                ;;
        esac
    done
    if [[ "$(id -u)" -ne "0" ]]; then
        echo "ERROR: the script can only be run as root. Aborting."
        exit 1
    fi
}


get_php_values() {
    if [ -f /var/cpanel/ApachePHPFPM/system_default_ ]; then
        apache_dir="/etc/httpd/conf"
    elif [ -f /etc/apache2/conf/httpd.conf ]; then
        apache_dir="/etc/apache2/conf"
    fi

}


get_values() {
    # Caclulating Apache workers / serverlimit / max threads
    if [[ "${tune_apache}" == "1" ]]; then
        if [ -f /etc/httpd/conf/httpd.conf ]; then
            apache_dir="/etc/httpd/conf"
        elif [ -f /etc/apache2/conf/httpd.conf ]; then
            apache_dir="/etc/apache2/conf"
        else
            echo "ERROR: something is seriously fucked up, httpd.conf not found in /etc/httpd/conf and /etc/apache2/conf, aborting"
            exit 1
        fi
        if [[ ! -f /etc/cpanel/ea4/ea4.conf ]]; then
            no_ea4="1"
            echo "WARNING: cPanel EasyApache4 config file (/etc/cpanel/ea4/ea4.conf) not found, attempting to read variables directly from Apache config."
            max_request_workers="$(grep "MaxRequestWorkers" $apache_dir/httpd.conf | awk '{print $2}')"
            server_limit="$(grep "ServerLimit" $apache_dir/httpd.conf | awk '{print $2}')"
        else
            echo "cPanel EasyApache4 config file (/etc/cpanel/ea4/ea4.conf) found, reading variables from it."
            max_request_workers="$(grep "maxclients" /etc/cpanel/ea4/ea4.conf | grep -o "[[:digit:]]" | tr -d '\n')"
            server_limit="$(grep "serverlimit" /etc/cpanel/ea4/ea4.conf | grep -o "[[:digit:]]" | tr -d '\n')"
        fi
        echo "Current MaxRequestWorkers: $max_request_workers"
        echo "Current ServerLimit: $server_limit"
        echo "Getting average memory usage of Apache processes (in kb)"
        avg_mem="$(ps -ylC httpd --sort:rss | grep -v RSS | awk '{sum+=$8} END {print sum / NR}' | cut -d'.' -f1)"
        if [[ -z "$avg_mem" ]]; then
            echo "WARNING: unable to get average memory usage of Apache process (apache probably not running, using default value of 10000K(10M)"
            avg_mem="${def_apache_avg_mem}"
        else
            echo "Average memory usage of Apache process is: $avg_mem K"
        fi
        t_mem="$(grep -i MemTotal /proc/meminfo | awk '{print $2}')"
        echo "Total memory: $t_mem K"
        if [[ "${memory_preserve}" == "0" ]]; then
            a_mem="$(expr "${t_mem}" - $((t_mem / 5 )) - 500000)"
        else
            a_mem="$(expr "${t_mem}" - "${memory_preserve}")"
        fi
        if [[ "${a_mem}" -lt "0" ]]; then
            echo "ERROR: unable to proceed. Reserving required memory will put server over total memory limit"
        fi
        echo "Approximate memory we can allocate to Apache: ${a_mem} K"
        if [[ -z "${apache_optimal}" ]]; then
            apache_optimal="$( expr "$a_mem" / "$avg_mem" )"
            echo -e "Recommended value for MaxRequestWorkers and ServerLimit based on available data: $apache_optimal"
        else
            echo "Value for MaxRequestWorkers/ServerLimit (user override) - $apache_optimal"
        fi
    fi
    # Calculating PHP-FPM max_children and max_requests
    if [[ "${tune_phpfpm}" == "1" ]]; then
        if [[ -z "${phpfpm_max_req}" ]]; then
            phpfpm_max_req="${def_phpfpm_max_req}"
            echo "Recommended value for max_requests: $phpfpm_max_req"
        else
            echo "Value for max_requests (user override) - $phpfpm_max_req"
        fi
        if [[ -z "${phpfpm_max_child}" ]]; then
            phpfpm_max_child="${def_phpfpm_max_child}"
            echo "Recommended value for max_children: $phpfpm_max_child"
        else
            echo "Value for max_children (user override) - $phpfpm_max_child"
        fi
    fi
}


set_apache() {
    echo "Applying Apache config adjustments..."
    if [[ "$no_ea4" == "1" ]]; then
        sed -i "s/MaxRequestWorkers $max_request_workers/MaxRequestWorkers $apache_optimal/" $apache_dir/httpd.conf
        sed -i "s/ServerLimit $server_limit/ServerLimit $apache_optimal/" $apache_dir/httpd.conf
    else
        sed -i "s/\"maxclients\" : .*,$/\"maxclients\" : \"$apache_optimal\",/" /etc/cpanel/ea4/ea4.conf
        sed -i "s/\"serverlimit\" : .*,$/\"serverlimit\" : \"$apache_optimal\",/" /etc/cpanel/ea4/ea4.conf
    fi
    if [[ -f "$(which nginx 2>/dev/null)" ]]; then
        echo "Nginx web-server detected, applying appropiate restart sequence"
        { find ${apache_dir} -name '*lock*' -delete; service nginx stop && /scripts/rebuildhttpdconf && /scripts/restartsrv_httpd --stop && \
        /scripts/restartsrv_httpd --start && nginx -t && service nginx start; } 1>/dev/null
    else
        { find ${apache_dir} -name '*lock*' -delete; /scripts/rebuildhttpdconf && /scripts/restartsrv_httpd --stop && /scripts/restartsrv_httpd --start; } 1>/dev/null
    fi
}


set_phpfpm() {
    echo "Settings max_requests and max_children values for PHP-FPM"
    cat << EOF > /var/cpanel/ApachePHPFPM/system_pool_defaults.yaml
---
php_admin_flag_allow_url_fopen: 'on'
php_admin_flag_log_errors: 'on'
php_admin_value_disable_functions: exec,passthru,shell_exec,system
php_admin_value_doc_root: "\"[% documentroot %]/\""
php_admin_value_error_log: "[% homedir %]/logs/[% scrubbed_domain %].php.error.log"
php_admin_value_short_open_tag: 'on'
php_value_error_reporting: E_ALL & ~E_NOTICE
pm_max_children: ${phpfpm_max_child}
pm_max_requests: ${phpfpm_max_req}
pm_process_idle_timeout: 10
EOF
    # shoutouts to Mikhail K
    if [[ -f "/etc/csf/csf.pignore" ]] && [[ "${phpfpm_max_req}" -ge "200" ]] && ! grep -q "/opt/cpanel/ea-php\*/root/usr/bin/php" /etc/csf/csf.pignore; then
        echo 'High value of max_requests detected. Addiding /opt/cpanel/ea-php*/root/usr/bin/php to /etc/csf/csf.pignore'
        echo '/opt/cpanel/ea-php*/root/usr/bin/php' >> /etc/csf/csf.pignore
        csf -r 1>/dev/null
    fi
    { find ${apache_dir} -name '*lock*' -delete; /scripts/restartsrv_httpd --stop; /scripts/php_fpm_config --rebuild; /scripts/rebuildhttpdconf; /scripts/restartsrv_apache_php_fpm; /scripts/restartsrv_httpd --start; } 1>/dev/null
}


apply_values() {
    while true; do
        if [[ "$auto_apply" == "1" ]]; then
            if [[ "${tune_apache}" == "1" ]]; then
                set_apache
            fi
            if [[ "${tune_phpfpm}" == "1" ]]; then
                set_phpfpm
            fi
            break
        else
            if [[ "$no_ea4" == "1" ]]; then
                echo "WARNING: cPanel EasyApache4 config file (/etc/cpanel/ea4/ea4.conf) not found. Changes will be applied directly in Apache config"
            fi
            read -rp "Apply recommended settings? (apache/php-fpm/both/exit) [A/p/b/e] " apply
            case $apply in
                A|a|apache)
                    set_apache
                    ;;
                P|p|php-fpm)
                    set_phpfpm
                    ;;
                b|both)
                    set_apache
                    set_phpfpm
                    ;;
                e|exit)
                    exit 0
                    ;;
                *)
                    echo "Please say a(apache), p(php-fpm), b(both) or e(exit)"
                    ;;
            esac
        fi
    done
}


post_check() {
    # make sure that settings were appliedApache is still alive after our changes
    grep -i "ServerLimit $apache_optimal" $apache_dir/httpd.conf || echo "ERROR: something went wrong, new ServerLimit is not set"
    grep -i "MaxRequestWorkers $apache_optimal" $apache_dir/httpd.conf || echo "ERROR: something went wrong, new ServerLimit is not set"
    service httpd status 1>/dev/null
    if [[ "$?" == "0" ]]; then
        echo "Apache is up!"
        exit 0
    else
        echo "ERROR: Apache is down!"
        exit 1
    fi
}
#######################
# END function definitions
#######################




#######################
# START main
#######################
parse_input "$@"
get_values
apply_values
if [[ "${convert_all_to_fpm}" == "1" ]]; then
    echo "Initiated conversion of all accounts to PHP-FPM"
    whmapi1 convert_all_domains_to_fpm
fi
if [[ "${change_mpm}" == "1" ]]; then
    echo "Started Apache MPM change"
    current_mpm="$(rpm -qa | grep ea-apache24-mod_mpm_)"
    cat << EOF > /root/mpm_change_yum_shell
remove $current_mpm
install $new_mpm
run
EOF
    yum shell -y /root/mpm_change_yum_shell 1>/dev/null
    echo "Finished Apache MPM change"
fi
post_check
#######################
# END main
#######################
