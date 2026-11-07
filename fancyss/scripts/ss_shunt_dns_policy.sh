#!/bin/sh
# Compile ordered explicit domain routing into SmartDNS AAAA address rules.
# The existing trusted resolver domain sets remain separate.
fss_shunt_write_aaaa_policy() {
    local config="$1" output="$2" work="$2.input.$$" temp="$2.new.$$"
    jq -r '
        .routing.rules[] |
        select(.inboundTag==null and .domain!=null and (.network//"tcp,udp")!="udp") |
        select(.outboundTag=="direct" or .outboundTag=="reject" or (.outboundTag|test("^proxy[0-9]+$"))) |
        .outboundTag as $target | .domain[] |
        select(test("^(full|domain|keyword):")) |
        [., (if $target=="direct" then "-6" else "#6" end)] | @tsv
    ' "$config" > "$work" || { rm -f "$work"; return 1; }
    LC_ALL=C awk -F '\t' '
        function suffix(name, parent) {
            return name==parent || (length(name)>length(parent) &&
                substr(name,length(name)-length(parent))=="." parent)
        }
        {
            split($1,parts,":"); kind=parts[1]; name=parts[2]; action=$2
            covered=0; ambiguous=0; base_action=action; base_found=0; exact_found=0
            for(i=1;i<=count;i++) {
                if(types[i]=="full" && names[i]==name) exact_found=1
                if(!base_found && ((types[i]=="keyword" && index(name,names[i])) ||
                    (types[i]=="full" && name==names[i]) ||
                    (types[i]=="domain" && suffix(name,names[i])))) {
                    base_action=actions[i]; base_found=1
                }
                if (types[i]=="keyword") {
                    if(kind=="full" && index(name,names[i])) {action=actions[i];covered=2;break}
                    if(kind=="domain" && actions[i]!=action) ambiguous=1
                } else if(types[i]=="domain" && suffix(name,names[i])) {
                    covered=1;break
                } else if(kind=="full" && types[i]=="full" && name==names[i]) {
                    covered=1;break
                }
            }
            if(covered==1) next
            types[++count]=kind; names[count]=name; actions[count]=action
            if(kind=="keyword") next
            if(ambiguous) {
                # Arbitrary keyword matching cannot be represented by a suffix
                # rule. Keep the legacy conservative AAAA policy for that
                # subtree, with an exact exception when its root is DIRECT.
                printf "address /%s/#6\n",name
                if(base_action=="-6" && !exact_found) printf "address /-.%s/-6\n",name
                next
            }
            if(kind=="full") name="-." name
            printf "address /%s/%s\n",name,action
        }
    ' "$work" > "$temp"
    local result=$?
    rm -f "$work"
    [ "$result" = 0 ] && mv -f "$temp" "$output"
}
