"""Generate Ring's app icon SVG: a phone handset over a globe, in a macOS squircle.

Render AppIcon.svg to a 1024x1024 PNG (e.g. in a browser) and resize it into
Ring/Assets.xcassets/AppIcon.appiconset (16-512 pt, 1x and 2x)."""
import math, os
LROT=os.environ.get("LROT","-12"); RROT=os.environ.get("RROT","12"); TILT=os.environ.get("TILT","-8")
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
    <!-- handle: a deep arch; the ear and chin sit on its concave (lower) side -->
    <path d="M -170 40 C -175 -175, 175 -175, 170 40" fill="none" stroke="#34C759"
          stroke-width="104" stroke-linecap="butt"/>
    <!-- earpiece / mouthpiece: wider than the handle; their faces (darker) point into the
         curve, towards the face, tilted slightly towards each other -->
    <g transform="translate(-178 70) rotate({LROT})">
      <path d="M -120 -30 C -120 -70, 120 -70, 120 -30 L 112 30 C 108 50, -108 50, -112 30 Z" fill="#34C759"/>
      <rect x="-104" y="26" width="208" height="26" rx="13" fill="#248A3D"/>
    </g>
    <g transform="translate(178 70) rotate({RROT})">
      <path d="M -120 -30 C -120 -70, 120 -70, 120 -30 L 112 30 C 108 50, -108 50, -112 30 Z" fill="#34C759"/>
      <rect x="-104" y="26" width="208" height="26" rx="13" fill="#248A3D"/>
    </g>
  </g>
"""

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2F6FE4"/>
      <stop offset="1" stop-color="#1D4FB8"/>
    </linearGradient>
    <linearGradient id="globe" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#38BDF8"/>
      <stop offset="1" stop-color="#0EA5E9"/>
    </linearGradient>
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
    <!-- white outline around the handset (separates it from the globe), then a soft shadow -->
    <filter id="hsShadow" x="-30%" y="-30%" width="160%" height="160%">
      <feMorphology in="SourceAlpha" operator="dilate" radius="14" result="grown"/>
      <feFlood flood-color="#fff"/>
      <feComposite in2="grown" operator="in" result="outline"/>
      <feMerge result="outlined"><feMergeNode in="outline"/><feMergeNode in="SourceGraphic"/></feMerge>
      <feDropShadow in="outlined" dx="0" dy="8" stdDeviation="7" flood-color="#0A1F4D" flood-opacity="0.30"/>
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
  <circle cx="{gx}" cy="{gy}" r="{gr - 5}" fill="none" stroke="#fff" stroke-opacity="0.5" stroke-width="10"/>

  <!-- handset over the globe -->
  <defs>{handset}</defs>
  <g transform="translate({C} {C + 40}) rotate({TILT}) scale(0.9)" filter="url(#hsShadow)">
    <use href="#handset"/>
  </g>
</svg>
"""

open(os.path.join(os.path.dirname(os.path.abspath(__file__)), OUT), "w").write(svg)
print("wrote icon.svg")
