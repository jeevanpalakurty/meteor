#!/bin/bash

# This used to be run standalone, but now it's intended to always be
# invoked by 'meteor self-test' (and eventually we should port the
# whole thing to JavaScript, or at least the parts that don't
# duplicate our existing JS-based test coverage).
#
# To run it, set METEOR_TOOL_PATH to the 'meteor' script to use, plus,
# as usual, METEOR_WAREHOUSE_DIR if you want to stub out the
# warehouse.

set -e -x

cd "`dirname "$0"`"/../../..

# METEOR_TOOL_PATH is the path to the 'meteor' that we will use for
# our tests. There is a vestigal capability to default to running the
# 'meteor' that sets next to this script in a checkout, but we should
# probably just take that out.
if [ -z "$METEOR_TOOL_PATH" ]; then
    METEOR="`pwd`/meteor"
else
    METEOR="$METEOR_TOOL_PATH"
fi

if [ -z "$NODE" ]; then
    NODE="$(pwd)/scripts/node.sh"
fi

# Ensure that $NODE is set properly. Note that $NODE may not have access to
# modules from the dev bundle.
$NODE --version

TEST_TMPDIR=`mktemp -d -t meteor-cli-test-XXXXXXXX`
OUTPUT="$TEST_TMPDIR/output"
trap 'echo "[...]"; tail -25 $OUTPUT; echo FAILED ; rm -rf "$TEST_TMPDIR" >/dev/null 2>&1' EXIT

cd "$TEST_TMPDIR"


## Begin actual tests

echo "... --help"
$METEOR --help | grep "List the packages explicitly used" >> $OUTPUT
$METEOR run --help | grep "Port to listen" >> $OUTPUT
$METEOR test-packages --help | grep "Port to listen" >> $OUTPUT
$METEOR create --help | grep "Make a subdirectory" >> $OUTPUT
$METEOR update --help | grep "Updates the meteor release" >> $OUTPUT
$METEOR add --help | grep "Adds packages" >> $OUTPUT
$METEOR remove --help | grep "Removes a package" >> $OUTPUT
$METEOR list --help | grep "This will not list transitive dependencies" >> $OUTPUT
$METEOR bundle --help | grep "Package this project" >> $OUTPUT
$METEOR mongo --help | grep "Opens a Mongo" >> $OUTPUT
$METEOR deploy --help | grep "Deploys the project" >> $OUTPUT
$METEOR logs --help | grep "Retrieves the" >> $OUTPUT
$METEOR reset --help | grep "Reset the current" >> $OUTPUT
$METEOR test-packages --help | grep "Runs unit tests" >> $OUTPUT

echo "... not in dir"

$METEOR 2>&1 | grep "run: You're not in" >> $OUTPUT
$METEOR run 2>&1 | grep "run: You're not in" >> $OUTPUT
$METEOR add foo 2>&1 | grep "add: You're not in" >> $OUTPUT
$METEOR remove foo 2>&1 | grep "remove: You're not in" >> $OUTPUT
$METEOR list 2>&1 | grep "list: You're not in" >> $OUTPUT
$METEOR bundle foo.tar.gz 2>&1 | grep "bundle: You're not in" >> $OUTPUT
$METEOR mongo 2>&1 | grep "mongo: You're not in" >> $OUTPUT
$METEOR deploy automated-test 2>&1 | grep "deploy: You're not in" >> $OUTPUT
$METEOR reset 2>&1 | grep "reset: You're not in" >> $OUTPUT

echo "... create"

DIR="skel with spaces"
$METEOR create "$DIR"
test -d "$DIR"
test -f "$DIR/$DIR.js"

## Tests in a meteor project
cd "$DIR"
# run in a subdirectory, just to make sure this also works
cd .meteor

echo "... add/remove/list"

$METEOR search backbone | grep "backbone" >> $OUTPUT
! $METEOR list 2>&1 | grep "backbone" >> $OUTPUT
$METEOR add backbone 2>&1 | grep "backbone:" | grep -v "no such package" | >> $OUTPUT
$METEOR list | grep "backbone" >> $OUTPUT
grep backbone packages >> $OUTPUT # remember, we are already in .meteor
$METEOR remove backbone 2>&1 | grep "Removed top-level dependency on backbone" >> $OUTPUT
! $METEOR list 2>&1 | grep "backbone" >> $OUTPUT

echo "... bundle"

$METEOR bundle foo.tar.gz
tar tvzf foo.tar.gz >>$OUTPUT

cd .. # we're now back to $DIR
echo "... run"

MONGOMARK='--bind_ip 127.0.0.1 --smallfiles --nohttpinterface --port 9101'
# kill any old test meteor
# there is probably a better way to do this, but it is at least portable across macos and linux
# (the || true is needed on linux, whose xargs will invoke kill even with no args)
ps ax | grep -e 'meteor.js -p 9100' | grep -v grep | awk '{print $1}' | xargs kill || true

! $METEOR mongo >> $OUTPUT 2>&1
$METEOR reset >> $OUTPUT 2>&1

test ! -d .meteor/local
! ps ax | grep -e "$MONGOMARK" | grep -v grep >> $OUTPUT

PORT=9100
$METEOR -p $PORT >> $OUTPUT 2>&1 &
METEOR_PID=$!

sleep 5 # XXX XXX lame

test -d .meteor/local/db
ps ax | grep -e "$MONGOMARK" | grep -v grep >> $OUTPUT
curl -s "http://localhost:$PORT" >> $OUTPUT

echo "show collections" | $METEOR mongo

# kill meteor, see mongo is still running
kill $METEOR_PID

sleep 10 # XXX XXX lame. have to wait for inner app to die via keepalive!

! ps ax | grep "$METEOR_PID" | grep -v grep >> $OUTPUT
ps ax | grep -e "$MONGOMARK"  | grep -v grep >> $OUTPUT


echo "... rerun"

$METEOR -p $PORT >> $OUTPUT 2>&1 &
METEOR_PID=$!

sleep 5 # XXX XXX lame

ps ax | grep -e "$MONGOMARK" | grep -v grep >> $OUTPUT
curl -s "http://localhost:$PORT" >> $OUTPUT

kill $METEOR_PID
sleep 10 # XXX XXX lame. have to wait for inner app to die via keepalive!

ps ax | grep -e "$MONGOMARK" | grep -v grep | awk '{print $1}' | xargs kill || true
sleep 2 # need to make sure these kills take effect

echo "... test-packages"

mkdir -p "$TEST_TMPDIR/local-packages/die-now/"
cat > "$TEST_TMPDIR/local-packages/die-now/package.js" <<EOF
Package.describe({
  summary: "die-now",
  version: "1.0.0"
});
Package.on_test(function (api) {
  api.use('deps'); // try to use a core package
  api.add_files(['die-now.js'], 'server');
});
EOF
cat > "$TEST_TMPDIR/local-packages/die-now/die-now.js" <<EOF
if (Meteor.isServer) {
  console.log("Dying");
  process.exit(0);
}
EOF

$METEOR test-packages --once -p $PORT $TEST_TMPDIR/local-packages/die-now | grep Dying >> $OUTPUT 2>&1
# since the server process was killed via 'process.exit', mongo is still running.
ps ax | grep -e "$MONGOMARK" | grep -v grep | awk '{print $1}' | xargs kill || true
sleep 2 # make sure mongo is dead


$METEOR test-packages -p $PORT >> $OUTPUT 2>&1 &

METEOR_PID=$!

sleep 5 # XXX XXX lame

ps ax | grep -e "$MONGOMARK" | grep -v grep >> $OUTPUT
curl -s "http://localhost:$PORT" >> $OUTPUT

kill $METEOR_PID
sleep 10 # XXX XXX lame. have to wait for inner app to die via keepalive!

ps ax | grep -e "$MONGOMARK" | grep -v grep | awk '{print $1}' | xargs kill || true
sleep 2 # need to make sure these kills take effect

echo "... mongo message"

# Run a server on the same port as mongod, so that mongod fails to start up. Rig
# it so that a single connection will cause it to exit.
$NODE -e 'require("net").createServer(function(){process.exit(0)}).listen('$PORT'+1, "127.0.0.1")' &

sleep 1

$METEOR -p $PORT > error.txt || true

grep 'port was closed' error.txt >> $OUTPUT

# Kill the server by connecting to it.
$NODE -e 'require("net").connect({host:"127.0.0.1",port:'$PORT'+1},function(){process.exit(0);})'

echo "... settings"

cat > settings.json <<EOF
{ "foo" : "bar",
  "baz" : "quux"
}
EOF

cat > settings.js <<EOF
if (Meteor.isServer) {
  Meteor.startup(function () {
    if (!Meteor.settings) process.exit(1);
    if (Meteor.settings.foo !== "bar") process.exit(1);
    process.exit(0);
  });
}
EOF

$METEOR -p $PORT --settings 'settings.json' --once >> $OUTPUT
rm settings.js


# prepare die.js so that we have a server that loads packages and dies
cat > die.js <<EOF
if (Meteor.isServer)
  process.exit(1);
EOF


echo "... local-package-sets -- new package"

mkdir -p "$TEST_TMPDIR/local-packages/a-package-named-bar/"
cat > "$TEST_TMPDIR/local-packages/a-package-named-bar/package.js" <<EOF
Package.describe({
  summary: 'a-package-named-bar',
  version: '1.0.0'
});
Npm.depends({gcd: '0.0.0'});

Package.on_use(function(api) {
  api.add_files(['call_gcd.js'], 'server');
});
EOF

cat > "$TEST_TMPDIR/local-packages/a-package-named-bar/call_gcd.js" <<EOF
console.log("loaded a-package-named-bar");

var gcd = Npm.require('gcd');
console.log("gcd(4,6)=" + gcd(4,6));
EOF

! $METEOR add a-package-named-bar >> $OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR add a-package-named-bar >> $OUTPUT
$METEOR -p $PORT --once 2>&1 | grep "Cannot find anything about package -- a-package-named-bar" >> $OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR -p $PORT --once | grep "loaded a-package-named-bar" >> $OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR bundle $TEST_TMPDIR/bundle.tar.gz >> $OUTPUT
tar tvzf $TEST_TMPDIR/bundle.tar.gz >>$OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR -p $PORT --once | grep "gcd(4,6)=2" >> $OUTPUT


echo "... local-package-sets -- overridden package"

mkdir -p "$TEST_TMPDIR/local-packages/accounts-ui/"
cat > "$TEST_TMPDIR/local-packages/accounts-ui/package.js" <<EOF
Package.describe({
  summary: "accounts-ui - overridden",
  version: "1.0.0"
});

EOF

# Remove a-package-named-bar so that the local accounts-ui package is
# the only thing that determines whether we need to set PACKAGE_DIRS. If
# we were to leave a-package-named-bar in the app, then we would need to
# specify PACKAGE_DIRS to get output from 'meteor list', even before
# adding the local accounts-ui package, and we want to be able to run
# 'meteor list' without PACKAGE_DIRS set to see that it picks up the
# core accounts-ui package, not the local one.
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR remove a-package-named-bar >> $OUTPUT

! $METEOR add accounts-ui 2>&1 | grep "accounts-ui - overridden" >> $OUTPUT
$METEOR remove accounts-ui 2>&1 >> $OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR add accounts-ui 2>&1 | grep "accounts-ui - overridden" >> $OUTPUT
! $METEOR list | grep "accounts-ui - overridden" >> $OUTPUT
PACKAGE_DIRS="$TEST_TMPDIR/local-packages" $METEOR list | grep "accounts-ui - overridden" >> $OUTPUT


# remove die.js, we're done with package tests.
rm die.js




## Cleanup
trap - EXIT
rm -rf "$DIR"
echo PASSED
