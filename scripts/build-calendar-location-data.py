#!/usr/bin/env python3
"""Build the calendar's public-data location baseline, without user-location queries.

Install the build-only converter outside the app:
  npm install --prefix /tmp/calendar-coordinate-build proj4 --ignore-scripts
Then run this script with --output /tmp/calendar-locations-baseline.json.
The reviewed alias/identity correction pass must run before publishing the result.
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import tempfile
import urllib.request
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', required=True)
parser.add_argument('--source-dir', help='Reuse/store the downloaded public source files')
parser.add_argument('--proj4-module', default='/tmp/calendar-coordinate-build/node_modules/proj4')
args = parser.parse_args()
source_dir = pathlib.Path(args.source_dir or tempfile.mkdtemp(prefix='calendar-public-'))
source_dir.mkdir(parents=True, exist_ok=True)
sources = {
    'calendar-public-cities.json': 'https://data.gov.il/api/3/action/datastore_search?resource_id=b6ca0817-187e-470f-be34-4561c2e404b2&limit=5000',
    'calendar-public-localities.json': 'https://data.gov.il/api/3/action/datastore_search?resource_id=f01dec33-b09b-482d-8413-e9b4fcbc4d7f&limit=5000',
    'calendar-public-il.zip': 'https://download.geonames.org/export/dump/IL.zip',
    'calendar-public-ps.zip': 'https://download.geonames.org/export/dump/PS.zip',
    'calendar-public-world.zip': 'https://download.geonames.org/export/dump/cities15000.zip',
}
for name, url in sources.items():
    target = source_dir / name
    if not target.exists():
        with urllib.request.urlopen(url, timeout=60) as response:
            target.write_bytes(response.read())

# Government Latitude/Longitude columns are ITM northing/easting (EPSG:2039).
# https://epsg.io/2039.proj4 supplies this EPSG definition and WGS84 transform.
conversion = r'''
const fs=require('fs'),proj4=require(process.argv[1]);
const source=JSON.parse(fs.readFileSync(process.argv[2])).result.records;
const itm='+proj=tmerc +lat_0=31.7343936111111 +lon_0=35.2045169444444 +k=1.0000067 +x_0=219529.584 +y_0=626907.39 +ellps=GRS80 +towgs84=23.772,17.49,17.859,-0.3132,-1.85274,1.67299,-5.4262 +units=m +no_defs';
const result=[];
for(const row of source){
 const x=Number(row.Longitude),y=Number(row.Latitude);
 if(!Number.isFinite(x)||!Number.isFinite(y))continue;
 const [lon,lat]=proj4(itm,'EPSG:4326',[x,y]);
 if(lat>29&&lat<34&&lon>34&&lon<36)result.push({name:row.CityName.trim(),lat,lon});
}
process.stdout.write(JSON.stringify(result));
'''
converted = json.loads(subprocess.check_output([
    'node', '-e', conversion, args.proj4_module, str(source_dir / 'calendar-public-cities.json')
], text=True))
(source_dir / 'calendar-public-converted.json').write_text(json.dumps(converted, ensure_ascii=False))

def normalize(name):
    return re.sub(r'[\s\-־–—\x27\x22״׳\u0591-\u05c7]', '', name.lower().replace('קריית', 'קרית').replace('תקווה', 'תקוה'))

places = []
for stem, inner in [('world', 'cities15000.txt'), ('il', 'IL.txt'), ('ps', 'PS.txt')]:
    with zipfile.ZipFile(source_dir / ('calendar-public-' + stem + '.zip')) as archive:
        for line in archive.read(inner).decode().splitlines():
            c = line.split('\t')
            if c[6] != 'P' or c[7] in ['PPLQ', 'PPLH', 'PPLW', 'PPLX'] or not c[17]:
                continue
            aliases = [c[1], c[2]] + [n for n in c[3].split(',') if re.search('[א-ת]', n)]
            name = next((n for n in aliases if re.search('[א-ת]', n)), c[1])
            places.append([name, round(float(c[4]), 6), round(float(c[5]), 6), c[8], c[17], list(dict.fromkeys(aliases))])
for row in converted:
    places.append([row['name'], round(row['lat'], 6), round(row['lon'], 6), 'IL', 'Asia/Jerusalem', []])
lookup = {}
for row in places:
    for name in [row[0]] + row[5]:
        lookup.setdefault(normalize(name), []).append(row)
official = json.loads((source_dir / 'calendar-public-localities.json').read_text())['result']['records']
matched = []
for row in official:
    name = row['Name_Hebrew'].strip()
    options = [place for place in lookup.get(normalize(name), []) if place[3] in ['IL', 'PS']]
    if options:
        point = options[-1]
        matched.append([name, point[1], point[2], 'IL', 'Asia/Jerusalem', []])
unique = {(row[0], row[3]): row for row in places + matched}
data = {'updated': datetime.date.today().isoformat(), 'sources': list(sources.values()),
        'geonames_license': 'CC-BY-4.0', 'places': list(unique.values())}
pathlib.Path(args.output).write_text(json.dumps(data, ensure_ascii=False, separators=(',', ':')) + '\n')
print(f'Baseline: {len(unique)} places; {len(matched)}/{len(official)} official names. Run the reviewed alias correction pass before publishing.')
