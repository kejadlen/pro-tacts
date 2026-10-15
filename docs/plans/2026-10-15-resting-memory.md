# Resting memory

2026-10-15. The image runs the app on jemalloc, tuned to hand freed
memory back, instead of glibc's malloc. What a server holds while
nobody is using it is mostly what its allocator kept from the last
burst of requests, not what the app keeps.

## What was measured

The 600-card book from `2026-10-14-lists-read-the-index.md` (120 cards
with an 80 KB photo), served by `rackup` under Puma with its default
five threads. A hundred requests, five at a time, ran across PROPFIND,
`/contacts`, `/search`, the dashboard, and one card's GET. Then the
server sat idle for five seconds.

| | Boot | Peak | Idle after |
|---|---|---|---|
| glibc malloc | 67 MB | 249 MB | 248 MB |
| glibc, `MALLOC_ARENA_MAX=2` | 67 MB | | 173 MB |
| jemalloc, untuned | 70 MB | | 219 MB |
| jemalloc, as configured | 70 MB | 162 MB | 116 MB |

All figures are RSS. The Ruby heap at idle held 18 MB of live objects
over about 25 MB of pages (`ObjectSpace.memsize_of_all`,
`GC.stat`), and a full GC moved RSS by under 2 MB. Calling
`malloc_trim(0)` dropped the glibc process from 245 MB to 115 MB.
That means the rest was freed memory that glibc keeps, spread over an
arena per request thread.

## Why jemalloc and not a trim

A Puma `out_of_band` hook that calls `malloc_trim` gets glibc down to
about the same idle figure. It still peaks at glibc's height, though,
and it needs Fiddle, which is a bundled gem from Ruby 3.5 on and would
join the Gemfile. jemalloc lowers the peak as well. It comes from the
distribution's package and is loaded with `LD_PRELOAD`, so nothing in
the app knows about it. Running the test suite on a host is unchanged.

The settings:

- `narenas:2` caps the arenas whatever the thread count.
- `background_thread:true` returns memory without waiting for a later
  allocation to trigger it.
- `dirty_decay_ms:1000,muzzy_decay_ms:0` hand pages back a second
  after they go unused.

## What else was weighed

- **Fewer Puma threads.** Under jemalloc, two threads rested at 94 MB
  against five threads' 119 MB. That changes how many requests run at
  once, so it is a separate decision from this change.
- **Fewer gems at boot.** Every require together comes to about 38 MB
  over bare Ruby. Sentry (8 MB) and Bundler's setup (8 MB) are the
  largest; nothing stands out enough to drop.
