# Mesh recovery verification - 12 September 2026

All three Pis are connected over batman-adv again. Automatic recovery passed a
combined fault trial, and each Pi rejoined after an individual reboot. The final
check received all 138 packets across six directed mesh paths, including 18
full-size IPv4 packets. This operational follow-up is separate from the
September 7-8 experiment and its published payment measurements.

## Configuration and observed failure

| Node | Mesh address | Saved bat0 MAC | Current Ethernet address |
| --- | --- | --- | --- |
| pi1gateway | 10.10.0.1/24 | 42:dd:83:e7:7e:8b | 10.17.4.55 |
| pi2 | 10.10.0.2/24 | 82:d6:e3:11:03:bf | 10.17.4.56 |
| pi3 | 10.10.0.3/24 | a2:8a:1f:07:7e:04 | 10.17.4.58 |

The nodes use batman-adv 2025.4, BATMAN_IV, and onboard `wlan0` in IBSS mode.
The SSID is `lnmesh-20260907`, on channel 1 at 2412 MHz with 20 MHz width.
The running kernel is `6.18.34+rpt-rpi-2712`. The user previously described the
Pis as a few inches apart on a table; placement was not independently measured
again during this follow-up.

At 20:30 UTC, the gateway had an empty neighbor/originator table and could not
reach either leaf. Restarting only the gateway mesh service did not restore
the leaf connections. The user rebooted the gateway during diagnostics; it was
reachable again by 20:33:02 UTC, with its mesh service automatically started,
but still no neighbors.

The original experiment had disabled the leaves' Ethernet profiles. A LAN
discovery check finished at 20:33:49 UTC without finding a responding address
for either recorded leaf Ethernet MAC. After the user ran the existing LAN
restoration helper on both leaves, SSH access was available at 20:39 UTC.
Both leaves had been running for more than four days. Their mesh services
reported active, but their neighbor tables were empty. Restarting pi2's mesh
service restored its gateway path; restarting pi3's restored the remaining
paths. No leaf reboot or kernel-module reload was needed for that restoration.

This demonstrates that a successful one-shot service start did not establish
continued mesh connectivity. The precise driver/firmware cause of the earlier
radio isolation was not established. Reported BSSID values differed between
radios; a common effective BSSID is not claimed. Connectivity is established
by neighbor tables, mesh-bound traffic, and SSH over the mesh addresses.

## Simple recovery setup

`install-mesh-recovery.sh` installs the same configuration on all three nodes:

- The mesh service waits for `wlan0`, retries failed starts after ten seconds,
  and checks radio/address readiness before declaring startup successful.
- A systemd timer begins 90 seconds after boot and checks approximately every
  minute, with up to 15 seconds of random delay to stagger the nodes.
- A stopped/failed mesh service is started on the next check. Otherwise, three
  consecutive checks with no responsive peer trigger a mesh service restart.
- Checks bind pings to `bat0`. One responsive peer clears the failure count,
  avoiding disruption of a working link when the other peer is absent.
- Saved mesh addresses and MACs are retained. Automatic recovery does not
  reload kernel modules or reboot the Pi.

The final version was installed between 20:40:59 and 20:41:07 UTC. Bash syntax
and systemd unit validation passed. Deployed script and unit checksums matched
on all three nodes. Both the mesh service and health timer remained enabled
and active after reboot. LND and chrony were also active at the final check.

## Connectivity baseline

At 20:40:29-20:40:34 UTC controller time, ten pings in each of the six ordered
node pairs yielded 60/60 replies and zero loss. Each ping bound to `bat0`;
route inspection also selected `bat0`. SSH through the gateway reached both
leaves at their mesh addresses and reported `10.10.0.1` as the source.

## Unattended combined failure trial

At approximately 20:41:39 UTC, three faults were injected concurrently while
Ethernet remained available for observation. Timers ran on their normal
schedule; no manual recovery command was issued during this trial.

| Node | Injected fault | Service active again (s) | Both peers reachable (s) |
| --- | --- | ---: | ---: |
| pi1gateway | Mesh service stopped | 12.210 | 190.198 |
| pi2 | Radio left IBSS | 190.299 | 190.309 |
| pi3 | bat0 brought down | 181.239 | 189.388 |

All three succeeded and received new service invocation IDs. Each node again
listed both neighbors. Elapsed times use the originating Pi's monotonic clock.
The observation loop polled every three seconds, and ping checks also consume
time, so these are observed recovery times rather than exact link-up instants.
Because faults were concurrent, reaching both peers includes waiting for their
recovery. One trial does not establish a recovery-time distribution.

A preliminary gateway-only test at 20:35 UTC had manually invoked three failed
health checks and verified the restart trigger before leaf access was restored.
That earlier test did not measure the timer's natural delay or establish a
working peer connection. Its records are retained separately in the journal.

## Reboot verification

Each node was rebooted once, in the order below, after the fault trial passed.
Verification required a new Linux boot ID, the original bat0 MAC, active mesh
service and health timer, and successful mesh-bound pings to both peers.

| Node | Scheduled UTC | Fully checked UTC | Observed recovery (s) |
| --- | --- | --- | ---: |
| pi2 | 20:44:59 | 20:45:57 | 58.031 |
| pi3 | 20:46:00 | 20:46:58 | 58.063 |
| pi1gateway | 20:46:58 | 20:47:56 | 57.297 |

Elapsed time is measured on the controller with a monotonic clock, beginning
before the command that schedules reboot three seconds later. It includes
polling, SSH setup, and peer checks; it is not OS boot time. Polls were spaced
five seconds apart, with additional time spent on probes. These were graceful
software reboots, not abrupt power-removal tests. Hardware failure, absent
power, and a wedged operating system remain outside this service's scope.

## Final verification

At 20:48:08-20:48:14 UTC controller time, every directed node pair passed:

- 20 pings with 56-byte payloads per path: 120/120 replies.
- Three pings with 1472-byte payloads and IPv4 do-not-fragment per path:
  18/18 replies, exercising 1500-byte IP packets. This does not imply absence
  of batman-adv fragmentation below IP.
- Both mesh neighbors present on every node, with `wlan0` as the mesh link.
- Fresh SSH sessions to both leaves through the gateway's mesh address.

Ethernet management remains enabled on the leaves following the user's
restoration step. These checks therefore do not reproduce the earlier
experiment's offline isolation condition. Binding traffic to `bat0` and
checking its routes distinguishes the tested radio paths from Ethernet.

## Maintenance and evidence

From a Pi terminal:

```sh
systemctl status lnmesh-mesh lnmesh-mesh-health.timer
sudo journalctl -u lnmesh-mesh-health -n 20
sudo batctl meshif bat0 neighbors
```

To reapply the setup, copy `experiment/scripts/install-mesh-recovery.sh` onto
an already configured Pi and run `sudo bash install-mesh-recovery.sh`.

`mesh-recovery-2026-09-12.zip` contains this report, the installer, timestamped
command scripts and results, result summaries, the reboot harness, and a
SHA-256 manifest. Operational timestamps, return codes, and output hashes are
recorded in `evidence/events.jsonl`. Failed probes during outages are retained.
Wall-clock readings on different machines need not be identical; reported
durations use the monotonic clocks described above.

The local working journal is `.git/operations/mesh-repair-20260912/`. The
original 3,209-entry experiment manifest was checked with zero hash mismatches;
the earlier dataset, reports, and checksum manifest were not rewritten.
