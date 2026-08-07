#!/bin/bash
# Who has logged into this box, across the FULL retained auth log (incl. gz archives)?
echo "=== log coverage window ==="
head -1 /var/log/auth.log.1 2>/dev/null | cut -c1-19 | sed 's/^/    oldest uncompressed: /'
tail -1 /var/log/auth.log  2>/dev/null | cut -c1-19 | sed 's/^/    newest             : /'
zcat -f /var/log/auth.log.3.gz 2>/dev/null | head -1 | cut -c1-19 | sed 's/^/    oldest archived    : /'

echo
echo "=== every successful SSH auth, ALL retained logs, by user ==="
{ cat /var/log/auth.log /var/log/auth.log.1 2>/dev/null
  zcat -f /var/log/auth.log.2.gz /var/log/auth.log.3.gz 2>/dev/null
} | grep -hoE 'Accepted [a-z-]+ for [a-z]+ from [0-9.]+' | sort | uniq -c | sort -rn

echo
echo "=== non-SSH logins (console / logind sessions), by user ==="
{ cat /var/log/auth.log /var/log/auth.log.1 2>/dev/null
  zcat -f /var/log/auth.log.2.gz /var/log/auth.log.3.gz 2>/dev/null
} | grep -hoE "New session [0-9]+ of user '[a-z]+'" | grep -oE "user '[a-z]+'" | sort | uniq -c | sort -rn

echo
echo "=== failed / invalid attempts (noise level, and any targeted user) ==="
{ cat /var/log/auth.log /var/log/auth.log.1 2>/dev/null
  zcat -f /var/log/auth.log.2.gz /var/log/auth.log.3.gz 2>/dev/null
} | grep -hoE 'Failed password for (invalid user )?[a-z]+|Invalid user [a-z]+' | sort | uniq -c | sort -rn | head -8

echo
echo "=== sudo use, by user ==="
{ cat /var/log/auth.log /var/log/auth.log.1 2>/dev/null
  zcat -f /var/log/auth.log.2.gz /var/log/auth.log.3.gz 2>/dev/null
} | grep -hoE 'sudo: +[a-z]+ :' | sort | uniq -c | sort -rn | head -6
