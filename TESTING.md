# Testing Quill

Quill is tested end to end against a **real Ghost**, not mocks. The Ghost definition lives in
this repo (`testenv/docker-compose.yml`), so anyone with Docker on a reachable host can run it.

There are three parts:

| Suite | Where it runs | What it proves |
|---|---|---|
| `QuillUITests` | Simulator | The whole app: simulated Face ID, add a site, write, publish, check the post in Ghost, relaunch |
| `QuillTests` | Simulator | The real Publisher: publishing, the offline outbox, conflicts, double taps, lost responses |
| `GhostKitTests` | Mac | The API client on its own (`scripts/test-ghostkit.sh`) |

## Quick start

If you've already done the one-time setup below:

```sh
scripts/testenv.sh up     # start the test Ghost, open the tunnel, seed credentials
scripts/test-app.sh       # run everything on the iPhone simulator
SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh    # and on iPad
```

## One-time setup

**On your Mac**

1. Install Xcode (27.1 or later), including the iOS simulator runtime. Check with
   `xcrun simctl list runtimes`.
2. Install XcodeGen: `brew install xcodegen`.
3. Confirm the simulators exist: `xcrun simctl list devices available | grep -E "iPhone 18 Pro|iPad Pro 13"`.
   To use a different one, pass its name in `SIM`.

**On the Docker host**

You need a machine with Docker Compose that you can reach with `ssh <host>` without a password
prompt, as a user who can run `docker` and write to the target directory. The default is
`docker-server` and `/opt/ghost-dev`. To use another:

```sh
export QUILL_TEST_HOST=my-docker-box
export QUILL_TEST_DIR=/srv/ghost-dev
```

Port `2369` must be free on both machines. Ghost listens on the host's loopback only, so it's
never exposed to the network; your Mac reaches it through an SSH tunnel.

**Start it**

```sh
scripts/testenv.sh up
```

This copies the compose file to the host, starts Ghost, opens the tunnel, then creates a test
owner account and an Admin API key. Generated credentials go to `.dev/ghost-dev.env`, which is
gitignored. The first start takes about a minute.

Check it with `scripts/testenv.sh status`. You should see the container running, `tunnel: open`,
and `ghost at http://localhost:2369: 200`.

## Running tests

```sh
scripts/test-app.sh                                   # all app tests, iPhone
SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh       # all app tests, iPad
scripts/test-app.sh -only-testing:QuillUITests        # just the full UI flow
scripts/test-app.sh -only-testing:QuillTests          # just the Publisher tests
scripts/test-ghostkit.sh                              # API client, on the Mac
```

`test-app.sh` regenerates the Xcode project, boots the simulator, uninstalls any previous Quill
for a clean first run, enrols simulated Face ID, and keeps sending simulated face matches while
the tests run. Builds use ad-hoc signing, so no Apple account is needed.

Results land in `build/results.xcresult`. To see the screenshots the UI test captures at each
step, run `open build/results.xcresult`.

## Managing the test Ghost

| Command | What it does |
|---|---|
| `scripts/testenv.sh up` | Start or update, open the tunnel, seed if needed |
| `scripts/testenv.sh tunnel` | Reopen the tunnel, for example after the Mac slept |
| `scripts/testenv.sh status` | Show the container, tunnel and credentials |
| `scripts/testenv.sh reset` | **Delete all test posts** and start fresh with new credentials |
| `scripts/testenv.sh down` | Stop Ghost and close the tunnel, keeping its content |

Tests leave their posts behind. That's harmless, because each one uses a unique title. Run
`reset` whenever you want a clean site.

To look at the site or Ghost Admin, open <http://localhost:2369/ghost/> and sign in with
`GHOST_DEV_EMAIL` and `GHOST_DEV_PASSWORD` from `.dev/ghost-dev.env`.

## Safety

- The test Ghost shares nothing with the real journal: separate directory, container and
  database, and it isn't on the tailnet.
- Tests only use `GHOST_DEV_URL` and `GHOST_DEV_ADMIN_KEY`, so they can't touch a real site
  unless you point those at one. Don't.
- `.dev/` holds test credentials only and must stay gitignored.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `.dev/ghost-dev.env: No such file` | Run `scripts/testenv.sh up` |
| Publisher tests fail with connection errors | The tunnel dropped: `scripts/testenv.sh tunnel` |
| `bind: address already in use` on 2369 | Something else has the port. Find it with `lsof -i :2369` |
| Seed fails with 401 or the key stops working | Credentials and Ghost are out of step: `scripts/testenv.sh reset` |
| UI test stops at "Face ID unlock / Add Site didn't appear" | Open the Simulator and use Features → Face ID → Enrolled, then rerun |
| `Unable to find a device matching` | The `SIM` name doesn't exist; list them with `xcrun simctl list devices available` |
| Ghost won't start | `ssh $QUILL_TEST_HOST 'cd /opt/ghost-dev && docker compose logs --tail 50'` |

## Adding a test

Keep the suite small: end-to-end tests that protect a real behavior, not unit tests.

- Publishing behavior goes in `QuillTests/PublisherLiveTests.swift`. Use `harness()` and give
  posts a unique title with `UUID()`.
- Anything the user sees goes in `QuillUITests/PublishFlowUITests.swift`.
- Ghost's `updated_at` has one-second precision, so wait over a second between two edits when
  testing conflicts.
