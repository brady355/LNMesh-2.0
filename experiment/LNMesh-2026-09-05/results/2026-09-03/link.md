# Mesh link measurements 2026-09-03T20:28:40-05:00

## batman-adv originators (TQ of 255) and RTT
### from a
  2c:cf:67:a8:95:63 TQ=(251)
  2c:cf:67:c1:a0:46 TQ=(255)
  ping 10.10.0.2:  5.730/6.622/7.936/0.603 ms
  ping 10.10.0.3:  0.743/5.380/6.770/1.864 ms
### from b
  2c:cf:67:f4:eb:83 TQ=(255)
  2c:cf:67:c1:a0:46 TQ=(255)
  ping 10.10.0.1:  0.751/5.249/6.793/2.256 ms
  ping 10.10.0.3:  0.688/5.417/8.308/2.355 ms
### from c
  2c:cf:67:a8:95:63 TQ=(255)
  2c:cf:67:f4:eb:83 TQ=(255)
  ping 10.10.0.1:  0.669/4.311/7.406/2.597 ms
  ping 10.10.0.2:  0.802/5.951/8.140/2.005 ms

## iperf3 B -> A over bat0 (10 s, TCP)
iperf3: error while loading shared libraries: libsctp.so.1: cannot open shared object file: No such file or directory

## iperf3 B -> A over bat0 (10 s, TCP)
[  5]   0.00-10.00  sec  59.5 MBytes  49.9 Mbits/sec    0            sender
[  5]   0.00-10.02  sec  56.9 MBytes  47.6 Mbits/sec                  receiver
