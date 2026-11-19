"""Generate Ring's app icon SVG: a phone handset over a globe, in a macOS squircle.

Render AppIcon.svg to a 1024x1024 PNG (e.g. in a browser) and resize it into
Ring/Assets.xcassets/AppIcon.appiconset (16-512 pt, 1x and 2x)."""
import math, os
LROT=os.environ.get("LROT","24"); RROT=os.environ.get("RROT","-24"); TILT=os.environ.get("TILT","-32")
OUT=os.environ.get("OUT","AppIcon.svg")

S = 1024          # canvas
BOX = 824         # squircle size (Apple macOS icon grid)
C = S / 2
N = 5.0           # superellipse exponent (close to Apple's continuous-corner squircle)


def squircle(cx, cy, half, n=N, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + half * math.copysign(abs(c) ** (2 / n), c)
        y = cy + half * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


sq = squircle(C, C, BOX / 2)

# Globe
gx, gy, gr = C, C + 18, 292
meridians = "".join(
    f'<ellipse cx="{gx}" cy="{gy}" rx="{gr * k:.1f}" ry="{gr}" />' for k in (0.28, 0.62, 0.9)
)
parallels = ""
for lat in (-60, -30, 0, 30, 60):
    y = gy - gr * math.sin(math.radians(lat))
    w = gr * math.cos(math.radians(lat))
    # slight curve so parallels read as lines on a sphere
    bow = 26 * math.cos(math.radians(lat)) * (1 if lat >= 0 else 1)
    parallels += f'<path d="M {gx - w:.1f} {y:.1f} Q {gx:.1f} {y + bow:.1f} {gx + w:.1f} {y:.1f}" />'

# Handset, drawn horizontally around (0,0) then rotated and placed over the globe.
handset = f"""
  <g id="handset">
    <!-- handle -->
    <path d="M -200 0 C -150 -132, 150 -132, 200 0" fill="none" stroke="url(#hsBody)"
          stroke-width="84" stroke-linecap="round"/>
    <!-- earpiece and mouthpiece -->
    <g transform="translate(-214 30) rotate({LROT})">
      <rect x="-116" y="-64" width="232" height="128" rx="64" fill="url(#hsBody)"/>
      <rect x="-80" y="22" width="160" height="22" rx="11" fill="#000" opacity="0.10"/>
    </g>
    <g transform="translate(214 30) rotate({RROT})">
      <rect x="-116" y="-64" width="232" height="128" rx="64" fill="url(#hsBody)"/>
      <rect x="-80" y="22" width="160" height="22" rx="11" fill="#000" opacity="0.10"/>
    </g>
    <!-- highlight along the top of the handle -->
    <path d="M -168 -62 C -110 -140, 110 -140, 168 -62" fill="none" stroke="#fff"
          stroke-opacity="0.55" stroke-width="16" stroke-linecap="round"/>
  </g>
"""

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#3B82F6"/>
      <stop offset="1" stop-color="#1E3A8A"/>
    </linearGradient>
    <radialGradient id="globe" cx="0.36" cy="0.30" r="0.85">
      <stop offset="0" stop-color="#A5F3FC"/>
      <stop offset="0.45" stop-color="#22B8E8"/>
      <stop offset="1" stop-color="#0B4FA8"/>
    </radialGradient>
    <radialGradient id="globeShine" cx="0.33" cy="0.26" r="0.38">
      <stop offset="0" stop-color="#fff" stop-opacity="0.55"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="hsBody" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#5EE07F"/>
      <stop offset="1" stop-color="#1FA544"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.22"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="globeClip"><circle cx="{gx}" cy="{gy}" r="{gr}"/></clipPath>
    <clipPath id="sqClip"><path d="{sq}"/></clipPath>
    <filter id="iconShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.30"/>
    </filter>
    <filter id="hsShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="#0A1F4D" flood-opacity="0.45"/>
    </filter>
    <filter id="globeShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="12" stdDeviation="18" flood-color="#081A40" flood-opacity="0.40"/>
    </filter>
  </defs>

  <!-- squircle background -->
  <path d="{sq}" fill="url(#bg)" filter="url(#iconShadow)"/>
  <g clip-path="url(#sqClip)">
    <path d="{sq}" fill="url(#sheen)"/>
  </g>

  <!-- globe -->
  <g filter="url(#globeShadow)">
    <circle cx="{gx}" cy="{gy}" r="{gr}" fill="url(#globe)"/>
  </g>
  <g clip-path="url(#globeClip)" fill="none" stroke="#fff" stroke-opacity="0.42" stroke-width="9">
    {meridians}
    <line x1="{gx}" y1="{gy - gr}" x2="{gx}" y2="{gy + gr}"/>
    {parallels}
  </g>
  <circle cx="{gx}" cy="{gy}" r="{gr}" fill="url(#globeShine)"/>
  <circle cx="{gx}" cy="{gy}" r="{gr - 4}" fill="none" stroke="#fff" stroke-opacity="0.35" stroke-width="8"/>

  <!-- handset over the globe -->
  <defs>{handset}</defs>
  <g transform="translate({C + 6} {C + 70}) rotate({TILT})" filter="url(#hsShadow)">
    <use href="#handset"/>
  </g>
</svg>
"""

open(os.path.join(os.path.dirname(os.path.abspath(__file__)), OUT), "w").write(svg)
print("wrote icon.svg")
