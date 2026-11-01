# Testing Quill

Quill is tested end to end against a **real Ghost**, not mocks. The Ghost definition lives in
this repo (`testenv/docker-compose.yml`), so anyone with Docker on a reachable host can run it.

There are three parts:

| Suite | Where it runs | What it proves |
|---|---|---|
| `QuillUITests` | Simulator | The whole app: first-run setup, writing and publishing, then finding, editing and deleting past posts, appearance and app icon |
| `QuillTests` | Simulator | The real Publisher: publishing, the offline outbox, conflicts, double taps, lost responses, importing and deleting posts, paging |
| `GhostKitTests` | Mac | The API client on its own (`scripts/test-ghostkit.sh`) |

## Quick start

After the one-time setup below:

```sh
scripts/test-all.sh                                  # everything, on iPhone and iPad at once
scripts/test-app.sh                                  # everything, on the iPhone simulator
SIM="iPad Pro 13-inch (M5)" scripts/test-app.sh      # and on iPad
scripts/test-ghostkit.sh                             # the API client
```

You don't need to start anything first. Each run creates a fresh Ghost and deletes it when it ends, whether the tests pass, fail or you press Ctrl-C.

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

**Check it works**

```sh
scripts/testenv.sh start     # first run pulls the image, about a minute
scripts/testenv.sh status    # container running, tunnel: open, ghost ...: 200
scripts/testenv.sh destroy
```

`start` copies the compose file to the host, starts Ghost, opens the tunnel, then creates a test owner and an Admin API key. Credentials go to `.dev/ghost-dev.env`, which is gitignored and deleted by `destroy`.

## Micro.blog

`.dev/microblog.env` (gitignored) holds `MICROBLOG_TOKEN=<app token>`. With it, `test-app.sh` also
runs `MicroblogLiveTests` and `testMicroblogSite` against the real account. To skip them, leave
the file out and pass `-skip-testing:QuillUITests/PublishFlowUITests/testMicroblogSite`.

That account has real followers and cross-posts, so these tests:

- **Only create drafts.** A published post can reach followers before it could be deleted.
- **Delete what they make**, posts and images, and check it's gone.
- **Never tap the send button** in the UI test.

This means publishing a new post, and publishing an existing draft, can't be tested here.

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

Test runs handle this for you. To look at the site or Ghost Admin after a run, keep it:

```sh
KEEP_GHOST=1 scripts/test-app.sh
```

Then open <http://localhost:2369/ghost/> and sign in with `GHOST_DEV_EMAIL` and `GHOST_DEV_PASSWORD` from `.dev/ghost-dev.env`. Run `scripts/testenv.sh destroy` when you're done.

| Command | What it does |
|---|---|
| `scripts/testenv.sh start` | Delete anything left over and start a fresh Ghost |
| `scripts/testenv.sh destroy` | Stop Ghost, close the tunnel, **delete all test content and credentials** |
| `scripts/testenv.sh up` | Start or update without deleting content |
| `scripts/testenv.sh down` | Stop Ghost and close the tunnel, keeping content |
| `scripts/testenv.sh tunnel` | Reopen the tunnel, for example after the Mac slept |
| `scripts/testenv.sh status` | Show the container, tunnel and credentials |

Only run one test script at a time, because they share the same Ghost.

## Safety

- The test Ghost shares nothing with the real journal: separate directory, container and
  database, and it isn't on the tailnet.
- Tests only use `GHOST_DEV_URL` and `GHOST_DEV_ADMIN_KEY`, so they can't touch a real site
  unless you point those at one. Don't.
- `.dev/` holds test credentials only and must stay gitignored.

## Troubleshooting

| Symptom | Fix |
|---|---|
| A run was killed and left Ghost running | The next run clears it, or run `scripts/testenv.sh destroy` |
| `bind: address already in use` on 2369 | Something else has the port. Find it with `lsof -i :2369` |
| UI test stops at "Face ID unlock / Add Site didn't appear" | Open the Simulator and use Features → Face ID → Enrolled, then rerun |
| `Unable to find a device matching` | The `SIM` name doesn't exist; list them with `xcrun simctl list devices available` |
| Ghost won't start | `ssh $QUILL_TEST_HOST 'cd /opt/ghost-dev && docker compose logs --tail 50'` |

## Adding a test

Less is more. A test earns its place by covering a journey that would really hurt if it broke, not a
control, a layout or a setting. Check those by eye, and prove a one-off fix once without keeping the test.

- Publishing behavior goes in `QuillTests/PublisherLiveTests.swift`. Use `harness()` and give
  posts a unique title with `UUID()`.
- Anything the user sees goes in `QuillUITests/PublishFlowUITests.swift`.
- Ghost's `updated_at` has one-second precision, so wait over a second between two edits when
  testing conflicts.
