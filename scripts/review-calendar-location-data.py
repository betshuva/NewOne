#!/usr/bin/env python3
"""Apply reviewed locality aliases to a generated baseline.

Every reviewed record is selected by its original name, country and coordinates.
Changed upstream records stop this script for review, never shift an index repair
onto an unrelated town. Inputs and output must be explicitly supplied.
"""
import argparse,json,re,collections
from pathlib import Path
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--input',required=True)
parser.add_argument('--output',required=True)
parser.add_argument('--source-dir',required=True)
args=parser.parse_args()
path=Path(args.output)
p=json.loads(Path(args.input).read_text())
assert 'official_localities' not in p, 'Expected unreviewed baseline input'
g=json.loads((Path(args.source_dir)/'calendar-public-localities.json').read_text())['result']['records']
converted=json.loads((Path(args.source_dir)/'calendar-public-converted.json').read_text())
def reviewed_row(identity):
 matches=[i for i,row in enumerate(p['places']) if row[:4]==identity]
 assert len(matches)==1, ('Public source changed: review this locality before rebuilding',identity,matches)
 return matches[0]
reviewed={key:reviewed_row(value) for key,value in {31764: ['אשדות יעקב אחוד', 32.65829, 35.58138, 'IL'], 31763: ['אשדות יעקב מאחד', 32.66319, 35.58383, 'IL'], 31590: ['אבן יצחק', 32.55743, 35.07635, 'IL'], 31570: ['גת', 31.62748, 34.79398, 'IL'], 31013: ['זרעית', 33.09938, 35.28963, 'IL'], 31329: ['מרחביה', 32.60531, 35.30705, 'IL'], 31254: ['ניר דוד', 32.50413, 35.45656, 'IL'], 31668: ['אל-בוקיעה', 32.97803, 35.33362, 'IL'], 31167: ['רִיחָנִיָּה', 33.04904, 35.48815, 'IL'], 31381: ['לִי אוֹן', 31.67744, 34.93464, 'IL'], 31209: ['פּוֹרִיָּה עִלִּית', 32.7319, 35.54635, 'IL'], 31617: ['עין חרוד אחוד', 32.56371, 35.39027, 'IL'], 31653: ['דבירה', 31.412204, 34.824465, 'IL'], 33475: ["ג'ת", 31.62748, 34.79398, 'IL'], 31470: ['גַ׳לְג׳וּלְיָה', 32.15218, 34.95526, 'IL'], 31035: ['בית גן', 32.70598, 35.50409, 'IL'], 31304: ['מִשְׁמֶרֶת', 32.22676, 34.9186, 'IL'], 31199: ['כפר הנוער קרית יערים', 31.803, 35.102, 'IL'], 31193: ['רָמַת הַכּוֹבֵשׁ', 32.21745, 34.93803, 'IL'], 30953: ['קָצִיר', 32.70549, 35.61793, 'IL'], 33522: ['קריית יערים', 31.803, 35.102, 'IL']}.items()}
def norm(s):return re.sub(r'''[\s\-־–—'"״׳]''','',re.sub('[\u0591-\u05c7]','',s.strip().lower()).replace('קריית','קרית').replace('תקווה','תקוה'))
def aliasnorm(s):return re.sub(r'''[()*‘’“”]''','',norm(s)).replace('יי','י').replace('וו','ו')
def index(normalizer):
 d=collections.defaultdict(set)
 for i,r in enumerate(p['places']):
  if r[3]=='IL':
   for name in [r[0],*r[5]]:d[normalizer(name)].add(i)
 return d
names=index(norm);aliases=index(aliasnorm)
unknown=[r for r in g if norm(r['Name_Hebrew']) not in names]
manual={199:reviewed[31764],188:reviewed[31763],369:reviewed[31590],340:reviewed[31570],1130:reviewed[31013],66:reviewed[31329],256:reviewed[31254],536:reviewed[31668],540:reviewed[31167],1114:reviewed[31381],1313:reviewed[31209],89:reviewed[31617],849:reviewed[31653]}
for code,english in [(2710,'Umm el Faḥm'),(487,'Jīsh')]:
 candidates=[i for i,r in enumerate(p['places']) if r[3]=='IL' and english in [r[0],*r[5]]]
 assert len(candidates)==1,(code,english,candidates)
 manual[code]=candidates[0]
added=[]
for official in unknown:
 code=official['Code'];name=official['Name_Hebrew'].strip()
 # Government * industrial sites can share a settlement's name but a different identity.
 if 1700 <= code <=1799:continue
 candidates=aliases.get(aliasnorm(name),set())
 if code in manual:candidates={manual[code]}
 if not candidates:continue
 # Only the two published records of the same Ein Harod Meuhad are duplicated.
 if len(candidates)>1 and code!=82:continue
 for i in candidates:
  r=p['places'][i]
  r[5].append(name)
  added.append({'code':code,'official_name':name,'source_name':r[0]})
# Public raw alternate names can conflate distinct towns. Remove reviewed
# collisions; retain only canonical government rows for the authoritative code.
p['places'][reviewed[33475]][1:3]=[32.39805,35.03804] # GeoNames Jatt 293703, not Gat kibbutz.
for i,bad in {reviewed[31470]:['גלגל'],reviewed[31570]:["ג'ת"],reviewed[31035]:['יבנאל'],reviewed[31304]:['מתן'],reviewed[31199]:['קרית יערים','קִרְיַת יְעָרִים'],reviewed[31193]:['רָמוֹת הַשָּׁבִים'],reviewed[30953]:['קציר']}.items():
 bad={norm(v) for v in bad}
 p['places'][i][5]=[v for v in p['places'][i][5] if norm(v) not in bad]
# Only a youth-village coordinate exists in the public source for this town.
# Do not present that different institution as the municipality's location.
p['places'][reviewed[33522]][0]='כפר הנוער קרית יערים'
for i in [reviewed[30953]]:
 p['places'][i][0]='תל קציר'
names=index(norm);centers=collections.defaultdict(list)
for r in converted:centers[aliasnorm(r['name'])].append(r)
marked=0;updated=0;conflicts=[]
for official in g:
 code=official['Code'];name=official['Name_Hebrew'].strip()
 if code==1137:continue
 candidates=names.get(norm(name),set())
 if not candidates:continue
 exact=[i for i in candidates if p['places'][i][0]==name]
 canonical=[i for i in candidates if norm(p['places'][i][0])==norm(name)]
 # Prefer the official display name and then its punctuation-only equivalent.
 chosen=(exact or canonical or sorted(candidates))[0]
 r=p['places'][chosen]
 center=centers.get(aliasnorm(name),[])
 if not center:
  alternate=[]
  for alias in [r[0],*r[5]]:
   alternate.extend(centers.get(aliasnorm(alias),[]))
  unique={(v['lat'],v['lon']):v for v in alternate}
  if len(unique)==1:center=list(unique.values())
 if len(center)==1:
  r[1]=round(center[0]['lat'],6);r[2]=round(center[0]['lon'],6);updated+=1
 if len(r)>6 and r[6]!=code:
  r=[name,r[1],r[2],r[3],r[4],[],code];p['places'].append(r)
 else:
  if len(r)==6:r.append(code)
  else:r[6]=code
 r[0]=name
 marked+=1
names=index(norm)
covered=sum(bool(names.get(norm(r['Name_Hebrew']))) for r in g)
source='https://data.gov.il/api/3/action/datastore_search?resource_id=f01dec33-b09b-482d-8413-e9b4fcbc4d7f&limit=5000'
if source not in p['sources']:p['sources'].append(source)
p['official_localities']={'covered':covered,'total':len(g),'code_column':6}
p['verified_locality_aliases']=added
assert not conflicts,conflicts
path.write_text(json.dumps(p,ensure_ascii=False,separators=(',',':'))+'\n')
print(json.dumps({'added_alias_entries':len(added),'added_localities':len(set(r['code'] for r in added)),'covered':covered,'total':len(g),'official_rows':marked,'government_centers_used':updated,'conflicts':conflicts},ensure_ascii=False))
print(json.dumps(added,ensure_ascii=False))
