#!/bin/bash

visited_file=".visited_urls.txt"
archive_dir=""
max_processes=3
user_agent="WebCrawler/1.0"
max_depth=3
current_depth=0
initial_url=""
tmp_file=""
resume_search=false

# semaphores files

cleanup_semaphore="/tmp/.cleanup_semaphore"
archive_semaphore="/tmp/.archive_semaphore"
cleanup_called="/tmp/.cleanup_called"
log_semaphore="/tmp/.log_semaphore"

# initialze semaphores files
echo "0" > $cleanup_semaphore
echo "0" > $archive_semaphore
echo "0" > $log_semaphore
echo "0" > $cleanup_called

# log files 
log_file=".log.txt"

trap 'cleanup' INT TERM

show_help() {
    echo "Usage: $0 -o <dir> [-u <url>] [-R] [OPTIONS]"
    echo "Web Crawler Script"
    echo "Options:"
    echo "  -p <num>   Maximum processes (default: $max_processes)"
    echo "  -d <num>   Maximum depth level (default: $max_depth)"
    echo "  -R         Resume the search (optional, requires -o)"
    echo "  --help     Display this help message"
    exit 0
}


while getopts ":p:o:u:d:R-:" opt; do
    case $opt in
        p)
            max_processes="$OPTARG"
            ;;
        o)
            archive_dir="$OPTARG"
            ;;
        u)
            initial_url="$OPTARG"
            ;;
        d)
            max_depth="$OPTARG"
            ;;
        R)
            resume_search=true
            ;;

        -)
            case "${OPTARG}" in
                help)
                    show_help
                    ;;
                *)
                    echo "Invalid option: --${OPTARG}"
                    exit 1
                    ;;
            esac
            ;;
        \?)
            echo "Invalid option: -$OPTARG"
            exit 1
            ;;
        :)
            echo "Option -$OPTARG requires an argument."
            exit 1
            ;;
    esac
done


[[ -z "$archive_dir" ]] && echo "Error: Output directory (-o) is mandatory." && exit 1 
[[ ! -d "$archive_dir" ]] && echo "Error: Specified output (-o) is not a directory." && exit 1

tmp_file="/tmp/$visited_file.tmp"
visited_file="$archive_dir/$visited_file"
log_file="$archive_dir/$log_file"


log(){
    local message=$1

    wait_for_semaphore "$log_semaphore"

    lock "$log_semaphore"

    echo -e "[$(date "+%Y/%m/%d %H:%M:%S")] - $message" >> "$log_file"

    unlock "$log_semaphore"
}

set_cleanup_called() {
    echo "1" > "$cleanup_called"
}


is_cleanup_called() {
    [[ -e "$cleanup_called" && $(cat "$cleanup_called") -eq 1 ]]
}

wait_for_semaphore() {
    local semaphore=$1
    while [[ $(cat "$semaphore") -eq 1 ]]; do
        sleep 1
    done
}


lock(){
    local semaphore=$1
    echo "1" > "$semaphore"
}

unlock(){
    local semaphore=$1
    echo "0" > "$semaphore"
}

cleanup() {
    
    wait

    wait_for_semaphore "$cleanup_semaphore"

    if is_cleanup_called; then
        # Cleanup has already been called by another process
        exit 0
    fi

    lock "$cleanup_semaphore"

    log "Interrupted. Cleaning up..."

    set_cleanup_called

    log "Last URL: $(tail -n 1 $tmp_file)"

    mv "$tmp_file" "$visited_file"
    
    unlock "$cleanup_semaphore"
   
    exit 1
}


control_concurrency() {
    while [[ $(jobs | wc -l) -ge $max_processes ]]; do
        sleep 1
    done
}



archive_page() {

    wait_for_semaphore "$archive_semaphore"
   
    lock "$archive_semaphore"
    
    local url=$1
    local content=$2
    local timestamp=$(date +"%Y_%m_%d_%H_%M_%S")
    local filename="$archive_dir/$(echo $url | tr -s '/' | tr '/' '_')_$timestamp.html"

    mkdir -p "$archive_dir"
    
    echo "$content" > "$filename"
    
    log "Archived URL: $url content"

    unlock "$archive_semaphore"
}



crawl() {
    local url=$1
    local depth=$2

    log "Crawling: $url"
    
    content=$(curl -s -A "$user_agent" "$url")

    if [[ $? == 0 ]]; then
       
        echo "$url" >> "$tmp_file"

        archive_page "$url" "$content"

        if [[ $depth -le $max_depth ]]; then
        
        links=$(echo "$content" | grep -o '<a [^>]*href="[^"]*"' | grep -o '".*"' | tr -d '"')

        log "Extracted Links:\n$links"

        for link in $links; do
            if [[ $link == /* || $link == http* ]]; then

                if ! grep -q "^$link$" "$visited_file" && ! grep -q "^$link$" "$tmp_file"; then
                    crawl "$link" $((depth + 1)) &
                    control_concurrency
                fi
            else
                if ! grep -q "^$url/$link$" "$visited_file" && ! grep -q "^$url/$link$" "$tmp_file"; then
                    crawl "$url/$link" $((depth + 1)) &
                    control_concurrency
                fi
            fi
        done
        fi
    else
        log "Failed to fetch $url"
    fi

}

if [[ $resume_search == true ]]; then 

    [[ ! -e "$visited_file" || ! -s "$visited_file" ]] && echo "The script could not be resumed." && exit 1

    echo "Press CTRL + C to stop the script."

    log "#### Start Logging ####"

    last_url=$(tail -n 1 $visited_file)

    log "Resumed from: $last_url"

    crawl "$last_url" $current_depth & 

else

    [[ -z "$initial_url" ]] && echo "Error: Initial URL (-u) is required for a new crawl." && exit 1

    echo "Press CTRL + C to stop the script."
    
    log "#### Start Logging ####"

    touch "$visited_file"

    crawl "$initial_url" $current_depth & 

    control_concurrency
fi

wait
