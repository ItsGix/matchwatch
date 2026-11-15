#!/usr/bin/env python3
"""Generate tcpdump-like lines simulating game traffic. usage: gen.py scenario"""
import random, sys
random.seed(7)
PC="192.168.1.50"; SRV="203.0.113.128"; T0=1794320000.0
def line(t,src,sp,dst,dp,ln): return (t,f"{t:.6f} IP {src}.{sp} > {dst}.{dp}: UDP, length {ln}")
def stream(out, up, hz, dur, jit=0.0003, loss=0.0, freezes=(), clump=None, per_tick=1, start=0.0, stalls=(), srv=SRV, sport=30120, lport=3074):
    """clump=(period_s, hold_s): every period, packets are held for hold_s then released together"""
    n=int(dur*hz)
    for i in range(n):
        ts=start+i/hz
        if any(a<=ts<a+d for a,d in freezes): continue      # server sent nothing
        if any(a<=ts<a+d for a,d in stalls): continue       # PC sent nothing
        if random.random()<loss: continue
        arr=ts+abs(random.gauss(0,jit))
        if clump:
            ph=ts%clump[0]
            if ph<clump[1]: arr=ts-ph+clump[1]+random.random()*0.0002
        for p in range(per_tick):
            t=T0+arr+p*0.00005
            if up: out.append(line(t,PC,lport,srv,sport,random.randint(60,120)))
            else:  out.append(line(t,srv,sport,PC,lport,random.randint(200,900)))
sc=sys.argv[1]; out=[]
if sc=="good":
    stream(out,False,60,180); stream(out,True,60,180)
elif sc=="badserver":
    stream(out,False,60,180,jit=0.004,loss=0.02,freezes=[(40,0.25),(90,0.2),(140,0.3)]); stream(out,True,60,180)
elif sc=="clump":
    stream(out,False,60,180,clump=(2.0,0.08)); stream(out,True,60,180)
elif sc=="badpc":
    stream(out,False,60,180); stream(out,True,60,180,jit=0.002,stalls=[(x,0.15) for x in range(10,180,10)])
elif sc=="frag":
    stream(out,False,60,180,per_tick=2,loss=0.03); stream(out,True,60,180)
elif sc=="lobby":
    stream(out,False,10,40); stream(out,True,10,40)
    stream(out,False,60,120,start=40); stream(out,True,120,120,start=40,jit=0.0002)
elif sc=="noise":
    stream(out,False,60,120); stream(out,True,60,120)
    stream(out,False,50,120,srv="162.159.130.234",sport=50004,lport=51000,jit=0.003)  # voice-like
    stream(out,True,50,120,srv="162.159.130.234",sport=50004,lport=51000,jit=0.003)
    for i in range(300): out.append(line(T0+i*0.4,PC,40000+i,"8.8.4.4",9999,40))        # scatter
elif sc=="fps":
    stream(out,False,21,180,jit=0.0014); stream(out,True,146,180,jit=0.002,loss=0.2,stalls=[(60,0.5),(100,0.12)])
elif sc=="handshake":
    stream(out,False,2,3); stream(out,True,2,3)
    stream(out,False,21,200,start=32.6,jit=0.001); stream(out,True,89,200,start=32.6,jit=0.003)
elif sc=="sweep":
    # a game measuring its ping to twenty datacentres inside a second and a half, then, half a minute later,
    # reaching for the one server it will play on. Run with -v GAMES=files/games.list -v GEOF=test/geo_sweep.tsv
    for i in range(20):
        s=f"198.51.100.{10+i}"; p=30002+i*610
        for j in range(4):
            out.append(line(T0+5+i*0.06+j*0.3,PC,3074,s,p,48)); out.append(line(T0+5.02+i*0.06+j*0.3,s,p,PC,3074,48))
    stream(out,False,10,20,start=40,srv="198.51.100.200",sport=44998); stream(out,True,10,20,start=40,srv="198.51.100.200",sport=44998)
elif sc=="relay":
    # a game reaching for a server, with a few packets to its relay on the same port beside it. Run with
    # -v GAMES=files/games.list -v GEOF=test/geo_relay.tsv and a DATA folder whose sessions.tsv has a match on port 44998
    for j in range(8):
        for s in ("203.0.113.9","203.0.113.60"):
            out.append(line(T0+5+j*1.5,PC,3074,s,44998,90)); out.append(line(T0+5.02+j*1.5,s,44998,PC,3074,76))
elif sc=="bursts":
    # video from a content network on a port nobody has named: eleven seconds every minute, five times over
    for b in range(5):
        stream(out,False,400,11,start=5+b*60,srv="203.0.113.77",sport=19298,lport=54268); stream(out,True,20,11,start=5+b*60,srv="203.0.113.77",sport=19298,lport=54268)
elif sc=="short":
    stream(out,False,60,22); stream(out,True,60,22)
out.sort()
for _,l in out: print(l)
