"""Generate Ring's app icon SVG: a phone handset over a globe, in a macOS squircle.

Render AppIcon.svg to a 1024x1024 PNG (e.g. in a browser) and resize it into
Ring/Assets.xcassets/AppIcon.appiconset (16-512 pt, 1x and 2x)."""
import math, os
LROT=os.environ.get("LROT","-14"); RROT=os.environ.get("RROT","14"); TILT=os.environ.get("TILT","-22")
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
    <!-- handle: long and gently arched -->
    <path d="M -215 -6 Q 0 -112 215 -6" fill="none" stroke="url(#hsBody)" stroke-width="86"
          stroke-linecap="round"/>
    <!-- earpiece / mouthpiece: bell-shaped cups flaring towards the face (the concave side),
         tilted slightly towards each other; the darker ellipse is the opening -->
    <g transform="translate(-222 32) rotate({LROT})">
      <path d="M -52 -50 L 52 -50 C 72 -50 82 -40 88 -24 L 106 34 C 110 50 100 60 84 60 L -84 60 C -100 60 -110 50 -106 34 L -88 -24 C -82 -40 -72 -50 -52 -50 Z" fill="url(#hsBody)"/>
      <ellipse cx="0" cy="56" rx="96" ry="15" fill="url(#hsFace)"/>
    </g>
    <g transform="translate(222 32) rotate({RROT})">
      <path d="M -52 -50 L 52 -50 C 72 -50 82 -40 88 -24 L 106 34 C 110 50 100 60 84 60 L -84 60 C -100 60 -110 50 -106 34 L -88 -24 C -82 -40 -72 -50 -52 -50 Z" fill="url(#hsBody)"/>
      <ellipse cx="0" cy="56" rx="96" ry="15" fill="url(#hsFace)"/>
    </g>
    <!-- soft highlight along the top of the handle -->
    <path d="M -170 -44 Q 0 -122 170 -44" fill="none" stroke="#fff" stroke-opacity="0.35"
          stroke-width="12" stroke-linecap="round"/>
  </g>
"""

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2F6FE4"/>
      <stop offset="1" stop-color="#1D4FB8"/>
    </linearGradient>
    <radialGradient id="globe" cx="0.38" cy="0.32" r="0.8">
      <stop offset="0" stop-color="#7DD3FC"/>
      <stop offset="0.55" stop-color="#1FAEE8"/>
      <stop offset="1" stop-color="#0B6FBF"/>
    </radialGradient>
    <radialGradient id="globeShine" cx="0.33" cy="0.26" r="0.38">
      <stop offset="0" stop-color="#fff" stop-opacity="0.30"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="hsBody" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#6BE08A"/>
      <stop offset="0.55" stop-color="#34C759"/>
      <stop offset="1" stop-color="#1F9E43"/>
    </linearGradient>
    <radialGradient id="hsFace" cx="0.5" cy="0.4" r="0.6">
      <stop offset="0" stop-color="#1B7F37"/>
      <stop offset="1" stop-color="#145F29"/>
    </radialGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity="0.22"/>
      <stop offset="0.5" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <clipPath id="globeClip"><circle cx="{gx}" cy="{gy}" r="{gr}"/></clipPath>
    <clipPath id="sqClip"><path d="{sq}"/></clipPath>
    <filter id="iconShadow" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.30"/>
    </filter>
    <!-- soft glow behind the handset (blends it into the globe), then a gentle shadow -->
    <filter id="hsShadow" x="-35%" y="-35%" width="170%" height="170%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="16" result="blur"/>
      <feFlood flood-color="#E0F7FF" flood-opacity="0.75"/>
      <feComposite in2="blur" operator="in" result="glow"/>
      <feGaussianBlur in="SourceAlpha" stdDeviation="6" result="sblur"/>
      <feOffset in="sblur" dy="7" result="soff"/>
      <feFlood flood-color="#0A1F4D" flood-opacity="0.30"/>
      <feComposite in2="soff" operator="in" result="shadow"/>
      <feMerge><feMergeNode in="glow"/><feMergeNode in="shadow"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
    <filter id="globeShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feDropShadow dx="0" dy="6" stdDeviation="8" flood-color="#081A40" flood-opacity="0.22"/>
    </filter>
  </defs>

  <!-- squircle background -->
  <path d="{sq}" fill="url(#bg)" filter="url(#iconShadow)"/>

  <!-- globe -->
  <g filter="url(#globeShadow)">
    <circle cx="{gx}" cy="{gy}" r="{gr}" fill="url(#globe)"/>
  </g>
  <g clip-path="url(#globeClip)" fill="none" stroke="#fff" stroke-opacity="0.5" stroke-width="10">
    {meridians}
    <line x1="{gx}" y1="{gy - gr}" x2="{gx}" y2="{gy + gr}"/>
    {parallels}
  </g>
  <circle cx="{gx}" cy="{gy}" r="{gr}" fill="url(#globeShine)"/>
  <circle cx="{gx}" cy="{gy}" r="{gr - 5}" fill="none" stroke="#fff" stroke-opacity="0.45" stroke-width="10"/>

  <!-- handset over the globe -->
  <defs>{handset}</defs>
  <g transform="translate({C} {C + 40}) rotate({TILT}) scale(0.92)" filter="url(#hsShadow)">
    <use href="#handset"/>
  </g>
</svg>
"""

open(os.path.join(os.path.dirname(os.path.abspath(__file__)), OUT), "w").write(svg)
print("wrote icon.svg")
