#!/bin/sh
# tests/emulator/fill-scrollback.sh
# Generates several screens of clearly distinct, labeled content for scroll tests.
# Each section has a unique header and numbered lines so scroll position is
# immediately identifiable in screenshots.
#
# Usage: sh /tmp/fill-scrollback.sh

for section in A B C D E; do
  echo ""
  echo ">>> SECTION $section <<<"
  i=1
  while [ "$i" -le 20 ]; do
    printf "  %s-%02d  " "$section" "$i"
    case $section in
      A) printf "alpha bravo charlie delta echo foxtrot golf hotel" ;;
      B) printf "india juliet kilo lima mike november oscar papa" ;;
      C) printf "quebec romeo sierra tango uniform victor whiskey" ;;
      D) printf "one two three four five six seven eight nine ten" ;;
      E) printf "red orange yellow green blue indigo violet white" ;;
    esac
    echo ""
    i=$((i + 1))
  done
done
echo ""
echo ">>> END OF DATA <<<"
