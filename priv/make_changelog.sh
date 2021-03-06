#!/bin/sh

for TAG in $(git tag | tac); do
    VERSION="$(echo $TAG | tr -d 'v')"

    if [ -n "$1" ]; then
        VERSION+="-$1"
    fi

    DESCRIPTION=$(git tag -n -l $TAG | sed -E "s/^v[0-9]+\.[0-9]+\.[0-9]+[ \t\n]+(.*)/\1/g")
    AUTHOR=$(git show $TAG | head -n3 | tail -n2 | cut -d ' ' -f2- | tr -d '\n')

    echo "brainly-hive ($VERSION) unstable; urgency=low"
    echo
    echo "  * $DESCRIPTION"
    echo
    echo " -- $AUTHOR"
    echo
done
