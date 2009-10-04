#!/bin/bash
# Status Quo Ante
# Version 0.1.0 
#
# by Stefan Tomanek <stefan.tomanek@wertarbyte.de>
# http://wertarbyte.de/status-quo-ante.shtml
#
# Save the running network configuration to a directory:
# $ sqa.sh save /tmp/network-dump
#
# Restore the configuration from a directory:
# $ sqa.sh restore /tmp/network-dump

DUMP="ip_addr ip_rule ip_route iptables"

IP="/bin/ip"
IPTABLES_SAVE="/sbin/iptables-save"
IPTABLES_RESTORE="/sbin/iptables-restore"

abort() {
    MSG=$1
    echo $MSG >&2
    exit 1
}

write_file() {
    FILE=$1
    if [ -e $FILE ]; then
        # prevent symlink attacks
        rm $FILE
    fi
    cat - > $FILE
}

save() {
    DIR=$1

    if [ ! -d "$DIR" ]; then
        mkdir -p "$DIR" || abort "Unable to create directory '$DIR'!";
    fi
    
    for PROC in $DUMP; do
        ${PROC}_save $DIR
    done
}

restore() {
    DIR=$1

    if [ ! -d "$DIR" ]; then
        abort "Directory '$DIR' not found!";
    fi

    for PROC in $DUMP; do
        ${PROC}_restore $DIR
    done
}

ip_addr_save() {
    DIR=$1
    $IP -o addr show | write_file "$DIR/ip_addr"
}

ip_addr_restore() {
    DIR=$1
    # flush all addresses
    $IP -o link | while IFS=: read ID DEV REST; do
        apply $IP addr flush $DEV
    done

    # Now read from the dumped settings file
    awk '$3 == "inet" {
        i=4;
        while (i<NF) {
            printf $i" ";
            i++;
        };
        print "dev "$NF
    }' $DIR/ip_addr | while read CMD; do
        apply $IP addr add $CMD
    done
}

list_routing_tables() {
    # we ignore the routing table local/255
    $IP -o rule show | awk '
        BEGIN {
            DONE[255]=DONE["local"]=1;
        }

        {
            I=2;
            while (I<=NF) {
                if ($I == "lookup") {
                    TABLE=$(I+1);
                    if (! DONE[TABLE]++) {
                        print TABLE;
                    }
                    next;
                }
                I++;
            }
        }'
}

ip_route_save() {
    DIR=$1
    # first we have to look up the routing tables
    # we can ignore the rules with priority 0
    list_routing_tables | while read TABLE; do
        $IP route show table $TABLE | write_file $DIR/ip_route.$TABLE
    done
}

ip_route_restore() {
    DIR=$1

    # flush all existing routing tables
    list_routing_tables | while read TABLE; do
        apply $IP route flush table $TABLE
    done
    
    # process all dumped routing tables
    for FILE in $DIR/ip_route.*; do
        TABLE=$(basename $FILE | sed 's/^ip_route\.//')

        while read LINE; do
            apply $IP route add table $TABLE $LINE
        done < $FILE
    done
}

ip_rule_save() {
    DIR=$1

    $IP rule show | write_file "$DIR/ip_rule"
}

ip_rule_restore() {
    DIR=$1

    apply $IP rule flush

    sed -r 's/^([0-9]+):/\1/' "$DIR/ip_rule" | while read PREF RULE; do
        # ignore local rule, since it cannot be removed
        IGNORE=0;
        if [ "$PREF" == "0" ]; then
            if [ "$RULE" == "from all lookup local" -o "$RULE" == "from all lookup 255" ]; then
                IGNORE=1;
            fi
        fi
        if [ "$IGNORE" != "1" ]; then
            apply $IP rule add pref ${PREF} ${RULE}
        fi
    done
}

iptables_save() {
    DIR=$1

    if [ ! -x $IPTABLES_SAVE ]; then
        echo "'$IPTABLES_SAVE' not found, saving of iptables setup not available!"
    else
        $IPTABLES_SAVE -c | write_file $DIR/iptables
    fi
}

iptables_restore() {
    DIR=$1

    if [ ! -x $IPTABLES_RESTORE ]; then
        echo "'$IPTABLES_RESTORE' not found, saving of iptables setup not available!"
    else
        if [ "$DRYRUN" ]; then
            echo $IPTABLES_RESTORE -c \< $DIR/iptables
        else
            $IPTABLES_RESTORE -c < $DIR/iptables
        fi
    fi
}

function apply() {
    if [ "$DRYRUN" == "1" ]; then
        echo $*
    else
        $*
    fi
}

case "$1" in
    save)
        shift;
        save $*
    ;;
    restore)
        shift;
        DRYRUN=0
        restore $*
    ;;
    simulate|dryrun)
        shift
        DRYRUN=1
        restore $*
    ;;
    *)
        abort "Unknown operation";
    ;;
esac
