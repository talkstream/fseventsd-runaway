import os
import os
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),"..","figures")
SANS="-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO="Menlo, 'SF Mono', monospace"
BG="#fcfcfb"; INK="#0b0b0b"; INK2="#52514e"; GRID="#dcdbd6"; BLUE="#2a78d6"; ORANGE="#eb6834"; WARNBG="#fdeee6"
SRC="Data: macOS diagnostics on one MacBook Pro M3 Pro, Sep–Oct 2026"
def wrap(title,body,sub=None):
    s=f'<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675" role="img" aria-label="{title}">\n<title>{title}</title>\n'
    s+=f'<rect width="1200" height="675" fill="{BG}"/>\n'+body
    s+=f'<text x="1160" y="654" text-anchor="end" font-family="{SANS}" font-size="22" fill="{INK2}">{SRC}</text>\n</svg>\n'
    return s
def T(x,y,t,size=22,fill=INK,w="normal",anchor="start",mono=False):
    fam=MONO if mono else SANS
    return f'<text x="{x}" y="{y}" font-family="{fam}" font-size="{size}" font-weight="{w}" fill="{fill}" text-anchor="{anchor}">{t}</text>\n'
def save(name,svg):
    open(f"{OUT}/{name}.svg","w").write(svg)

# ---- fig1
def fig1():
    X0,X1,Y0,Y1=110,1130,570,130   # plot box; Y0 = baseline (0 GB), Y1 = 24 GB... extend to 26
    ymax=26.0
    def px(h): return X0+(X1-X0)*h/120.0
    def py(g): return Y0-(Y0-Y1)*g/ymax
    b=T(40,52,"fseventsd grew to 24 GB — about 800× Apple’s own budget",34,INK,"bold")
    b+=T(40,88,"Memory of one macOS daemon, 27 Sep – 1 Oct (GMT+7)",24,INK2)
    for g in (0,5,10,15,20,25):
        b+=f'<line x1="{X0}" y1="{py(g)}" x2="{X1}" y2="{py(g)}" stroke="{GRID}" stroke-width="1"/>\n'
        b+=T(X0-12,py(g)+8,f"{g}",22,INK2,anchor="end")
    b+=T(X0-12,Y1-8,"GB",22,INK2,anchor="end")
    days=[(0,"27 Sep"),(24,"28 Sep"),(48,"29 Sep"),(72,"30 Sep"),(96,"1 Oct"),(120,"2 Oct")]
    for h,l in days:
        b+=f'<line x1="{px(h)}" y1="{Y0}" x2="{px(h)}" y2="{Y0+8}" stroke="{INK2}"/>\n'
        b+=T(px(h),Y0+34,l,22,INK2,anchor="middle")
    b+=f'<line x1="{X0}" y1="{Y0}" x2="{X1}" y2="{Y0}" stroke="{INK2}" stroke-width="1.5"/>\n'
    pts=[(11.5,0.01),(31.98,0.042),(34.25,0.04),(47.33,1.70),(73.65,7.93),(78.45,11.17),(119.33,24.0)]
    path=" ".join(f"{px(h):.1f},{py(g):.1f}" for h,g in pts)
    b+=f'<polyline points="{path}" fill="none" stroke="{BLUE}" stroke-width="3" stroke-linejoin="round"/>\n'
    # restart drop
    b+=f'<line x1="{px(119.33)}" y1="{py(24)}" x2="{px(119.4)}" y2="{py(0.0075)}" stroke="{ORANGE}" stroke-width="3" stroke-dasharray="8 6"/>\n'
    for h,g in pts[3:]:
        b+=f'<circle cx="{px(h)}" cy="{py(g)}" r="6" fill="{BLUE}" stroke="{BG}" stroke-width="2"/>\n'
    b+=f'<circle cx="{px(119.4)}" cy="{py(0.0075)}" r="7" fill="{BG}" stroke="{ORANGE}" stroke-width="3"/>\n'
    # annotations
    b+=T(px(34.25)+14,py(1.70)-12,"28 Sep 23:20: 1.7 GB",22,INK)
    b+=T(px(73.65)-14,py(7.93)-14,"30 Sep 01:39: 7.93 GB",22,INK,anchor="end")
    b+=T(px(78.45)-14,py(11.17)-14,"30 Sep 06:27: 11.17 GB",22,INK,anchor="end")
    b+=T(px(119.33)-16,py(24)-4,"1 Oct 23:20: 24 GB",22,INK,"bold",anchor="end")
    b+=T(px(119.33)-16,py(24)+24,"≈800× the 30 MB budget",24,INK,"bold",anchor="end")
    b+=T(px(119.4)-18,py(0.0075)-20,"after restart: 7.4 MB",22,INK,anchor="end")
    b+=T(X0+14,py(0.01)-62,"27 Sep \u2013 28 Sep 10:15:",22,INK)
    b+=T(X0+14,py(0.01)-36,"10\u201342 MB (normal)",22,INK)
    # budget line
    b+=f'<line x1="{X0}" y1="{py(0.03)-1}" x2="{X1}" y2="{py(0.03)-1}" stroke="{ORANGE}" stroke-width="3"/>\n'
    b+=T(px(84),py(6.6),"Apple\u2019s budget: 30 MB",24,INK,"bold")
    b+=T(px(84),py(6.6)+26,"the orange line along the axis",22,INK2)
    b+=T(40,654,"Lines join sparse samples.",22,INK2)
    return b
save("fig1-memory-timeline",wrap("fseventsd memory over time, 27 Sep to 1 Oct, reaching 24 GB against a 30 MB budget",fig1()))

# ---- fig2: hysteresis
def fig2():
    # events/s per day from log-file event IDs (evidence/events-per-day.txt), 14 Sep .. 1 Oct
    ev=[73,56,72,93,124,199,49,65,479,1023,1265,2117,3175,4694,5715,700,1107,317]
    labels=["14","","","","","19","","","22","","","25","","","28","","","1 Oct"]
    X0,X1=110,1140; nd=18; step=(X1-X0)/nd; bw=40
    def xd(d): return X0+step*d          # d = days since 14 Sep 00:00
    b=T(40,50,"The flood passed. The damage stayed.",34,INK,"bold")
    b+=T(40,86,"Same days, two measures, each on its own axis",24,INK2)
    PT,PB=150,330
    b+=T(X0,PT-14,"File events per second, daily average",24,INK,"bold")
    b+=f'<line x1="{X0}" y1="{PB}" x2="{X1}" y2="{PB}" stroke="{INK2}" stroke-width="1.5"/>\n'
    for i,v in enumerate(ev):
        h=(PB-PT-36)*v/5715; cx=xd(i+.5)
        b+=f'<rect x="{cx-bw/2}" y="{PB-h}" width="{bw}" height="{max(h,1.5)}" rx="3" fill="{ORANGE}"/>\n'
        if v>=1000 or i in (5,15): b+=T(cx,PB-h-8,f"{v:,}",20,INK,anchor="middle")
    b+=T(xd(1),PB-48,"normal: 50–200",22,INK2)
    # CPU share of one core, step function between Apple reports
    QT,QB=405,555
    b+=T(X0,QT-14,"fseventsd CPU, share of one core",24,INK,"bold")
    b+=f'<line x1="{X0}" y1="{QB}" x2="{X1}" y2="{QB}" stroke="{INK2}" stroke-width="1.5"/>\n'
    def yq(pct): return QB-(QB-QT-20)*pct/100
    segs=[(0,14+10.25/24,1.5),(14+10.25/24,16+1.65/24,16),(16+1.65/24,16+6.45/24,97),(16+6.45/24,17+23/24,98)]
    pts=[]
    for a,z,v in segs: pts += [(xd(a),yq(v)),(xd(z),yq(v))]
    b+='<polyline fill="none" stroke="'+BLUE+'" stroke-width="4" points="'+" ".join(f"{x:.1f},{y:.1f}" for x,y in pts)+'"/>\n'
    b+=T(xd(1),yq(1.5)-12,"1.5 % (average since boot)",22,INK)
    b+=T(xd(14.6),yq(16)-12,"16 %",22,INK)
    b+=T(xd(16.1)-8,yq(97)-12,"97–98 %",22,INK,"bold",anchor="end")
    for i,l in enumerate(labels):
        if l: b+=T(xd(i+.5),QB+30,l if " " in l else l+" Sep",20,INK2,anchor="middle")
    b+=T(40,612,"Events: from log-file event IDs; 12–13 Sep (about 550/s) not shown. CPU: Apple Jetsam reports, then ps.",22,INK2)
    return b
save("fig2-hysteresis",wrap("File events per second per day, 14 September to 1 October, peaking at 5,715 on 28 September, and fseventsd CPU share rising from 1.5 percent to 98 percent of a core after the flood passed",fig2()))

# ---- fig3
def fig3():
    b=T(40,52,"One restart, and the Mac got its headroom back",34,INK,"bold")
    rows=[("fseventsd memory","24 GB","7.4 MB"),
          ("fseventsd CPU","~100 % of a core","0 %"),
          ("Swap used","13.2 GB","1.5 GB"),
          ("CPU temperature","70.3 °C","57.6 °C"),
          ("System power","21.2 W","12.6 W")]
    CB,CA=620,960
    b+=T(CB,112,"BEFORE",24,INK2,"bold",anchor="middle")
    b+=T(CA,112,"AFTER RESTART",24,INK2,"bold",anchor="middle")
    y=130; rh=84
    for i,(l,a,c) in enumerate(rows):
        t=y+i*rh
        b+=f'<rect x="40" y="{t}" width="1120" height="{rh-10}" rx="10" fill="#f1f0ec"/>\n'
        cy=t+(rh-10)/2+10
        b+=T(64,cy,l,28,INK)
        b+=f'<circle cx="{CB-170}" cy="{cy-9}" r="7" fill="{ORANGE}"/>\n'
        b+=T(CB,cy,a,32,INK,"bold",anchor="middle")
        b+=T(785,cy,"→",32,INK2,anchor="middle")
        b+=f'<circle cx="{CA-100}" cy="{cy-9}" r="7" fill="{BLUE}"/>\n'
        b+=T(CA,cy,c,32,INK,"bold",anchor="middle")
    b+=T(40,620,"Temperature and power: 10 one-second macmon samples each. Memory: footprint, then RSS. Load not controlled.",22,INK2)
    return b
save("fig3-before-after",wrap("Before and after restarting fseventsd: memory 24 GB to 7.4 MB, swap 13.2 to 1.5 GB, CPU temperature 70.3 to 57.6 C, power 21.2 to 12.6 W",fig3()))

# ---- fig4
def fig4():
    b=T(40,52,"The fix: check → save evidence → restart",34,INK,"bold")
    steps=[("1","Check","bash fseventsd-check.sh","Is fseventsd the one eating memory and CPU?"),
           ("2","Save evidence","sudo bash fseventsd-restart.sh","The script saves evidence first, before touching anything."),
           ("3","Restart","kill -TERM &lt;pid&gt;","Run by the script; launchd respawns the daemon at once.")]
    y=84
    for i,(n,t,c,d) in enumerate(steps):
        top=y+i*128
        b+=f'<rect x="40" y="{top}" width="1120" height="116" rx="12" fill="#f1f0ec"/>\n'
        b+=f'<circle cx="92" cy="{top+58}" r="30" fill="{BLUE}"/>\n'
        b+=T(92,top+68,n,30,"#ffffff","bold",anchor="middle")
        b+=T(142,top+40,t,30,INK,"bold")
        b+=f'<rect x="142" y="{top+54}" width="470" height="46" rx="8" fill="#1a1a19"/>\n'
        b+=T(160,top+86,c,24,"#ffffff",mono=True)
        # description right, two lines
        words=d.split(" "); l1="";l2="";full=False
        for w in words:
            if not full and len(l1)+len(w)<=30: l1+=w+" "
            else: full=True; l2+=w+" "
        b+=T(640,top+66,l1.strip(),22,INK2)
        b+=T(640,top+94,l2.strip(),22,INK2)
    wy=84+3*128+4
    b+=f'<rect x="40" y="{wy}" width="1120" height="96" rx="12" fill="{WARNBG}" stroke="{ORANGE}" stroke-width="3"/>\n'
    b+=T(70,wy+40,"Warning",26,INK,"bold")
    b+=T(190,wy+40,"launchctl kickstart is blocked by SIP;",26,INK)
    b+=T(70,wy+76,"restarting wipes event history — save evidence first.",26,INK)
    return b
save("fig4-fix-card",wrap("Fix card: check, save evidence, restart fseventsd; kickstart is blocked by SIP and restarting wipes event history",fig4()))
