'use strict';
// Shared with the inline web editor; the parity test keeps both copies identical.
function createAuditColumnFormats(){
 const numeric=new Set(['dispatch_sent_count','dispatch_failed_count','event_count','attempt','step_total','provider_calls_used','provider_calls_limit','person_count','face_count','confidence','http_status','affected_count','frame_index','input_tokens','output_tokens','cached_input_tokens','total_tokens','cost_ils','operation_input_tokens','operation_output_tokens','operation_total_tokens','operation_cost_ils','fx_rate','event_id','parent_event_id','initiator_identifier','recipient_identifier']);
 const controls=new Set(['expand','select','details','preview','stopped_evidence','findings','dispatch_recipients']);
 const dates=['dd/MM/yy HH:mm:ss.SS','dd/MM/yyyy HH:mm:ss','dd/MM/yyyy','dd/MM/yy','yyyy-MM-dd','HH:mm:ss.SS','HH:mm'];
 const durations=['mm:ss','hh:mm:ss','seconds'];
 const types={auto:'ברירת מחדל',text:'טקסט',number:'מספר',currency:'מטבע',percent:'אחוזים',date:'תאריך ושעה',duration:'משך זמן'};
 function kind(key){return controls.has(key)?'control':['created_at','fx_date'].includes(key)?'date':['duration_ms','elapsed_ms','frame_timestamp'].includes(key)?'duration':numeric.has(key)?'number':'text';}
 function allowed(key){const k=kind(key);return k==='control'?['auto']:k==='number'?['auto','text','number','currency','percent']:k==='date'?['auto','text','date']:k==='duration'?['auto','text','number','duration']:['auto','text'];}
 function valid(key,f){
  if(!f||typeof f!=='object'||Array.isArray(f)||!allowed(key).includes(f.type))return false;
  const keys=f.type==='number'||f.type==='percent'?['type','decimals','grouping']:f.type==='currency'?['type','decimals','grouping','currency']:f.type==='date'?['type','pattern']:f.type==='duration'?['type','pattern','decimals']:['type'];
  if(Object.keys(f).some(k=>!keys.includes(k)))return false;
  if(keys.includes('decimals')&&(!Number.isInteger(f.decimals)||f.decimals<0||f.decimals>10))return false;
  if(keys.includes('grouping')&&typeof f.grouping!=='boolean')return false;
  if(f.type==='currency'&&!['ILS','USD','EUR'].includes(f.currency))return false;
  if(f.type==='date'&&!dates.includes(f.pattern))return false;
  if(f.type==='duration'&&(!durations.includes(f.pattern)||f.decimals>3))return false;
  return true;
 }
 function defaults(type){return type==='number'||type==='percent'?{type,decimals:2,grouping:true}:type==='currency'?{type,decimals:2,grouping:true,currency:'ILS'}:type==='date'?{type,pattern:dates[0]}:type==='duration'?{type,pattern:'mm:ss',decimals:2}:{type};}
 function normalize(saved,keys){return Object.fromEntries(Object.entries(saved&&typeof saved==='object'&&!Array.isArray(saved)?saved:{}).filter(([key,f])=>keys.includes(key)&&valid(key,f)&&f.type!=='auto'));}
 function move(order,key,position){if(!Number.isInteger(position)||position<1||position>order.length||!order.includes(key))throw Error('יש להזין מיקום בין 1 ל־'+order.length);const next=order.filter(k=>k!==key);next.splice(position-1,0,key);return next;}
 function decimal(value,places,grouping=false,shift=0){
  const m=/^(-?)(\d+)(?:\.(\d+))?(?:e([+-]?\d+))?$/i.exec(String(value));if(!m||String(value).length>200)return null;
  const exponent=Number(m[4]||0);if(Math.abs(exponent)>100)return null;
  const digits=BigInt(m[2]+(m[3]||'')),power=exponent-(m[3]||'').length+places+shift;
  const scaled=power>=0?digits*10n**BigInt(power):(digits+10n**BigInt(-power)/2n)/10n**BigInt(-power);
  const padded=String(scaled).padStart(places+1,'0'),whole=places?padded.slice(0,-places):padded;
  return (m[1]&&scaled!==0n?'-':'')+(grouping?whole.replace(/\B(?=(\d{3})+(?!\d))/g,','):whole)+(places?'.'+padded.slice(-places):'');
 }
 function format(key,value,f){
  if(value==null||value===''||!valid(key,f)||f.type==='auto')return null;
  if(f.type==='text')return String(value);
  if(['number','currency','percent'].includes(f.type)){
   const shift=f.type==='percent'?(key==='confidence'?0:2):kind(key)==='duration'?-3:0;
   const n=decimal(value,f.decimals,f.grouping,shift);return n==null?null:f.type==='currency'?({ILS:'₪',USD:'$',EUR:'€'}[f.currency]+n):f.type==='percent'?n+'%':n;
  }
  if(f.type==='date'){
   if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}(T.*)?$/.test(value))return null;
   const date=value.length===10?new Date(value+'T00:00:00'):new Date(value);if(!Number.isFinite(date.getTime()))return null;
   const two=n=>String(n).padStart(2,'0'),parts={yyyy:String(date.getFullYear()),yy:two(date.getFullYear()%100),MM:two(date.getMonth()+1),dd:two(date.getDate()),HH:two(date.getHours()),mm:two(date.getMinutes()),ss:two(date.getSeconds()),SS:two(Math.floor(date.getMilliseconds()/10))};
   return f.pattern.replace(/yyyy|yy|MM|dd|HH|mm|ss|SS/g,token=>parts[token]);
  }
  if(f.type==='duration'){
   const raw=decimal(value,f.decimals,false,-3);if(raw==null||raw.startsWith('-'))return null;
   if(f.pattern==='seconds')return raw;
   const [sec,fraction]=raw.split('.'),n=BigInt(sec),two=n=>String(n).padStart(2,'0');
   const prefix=f.pattern==='hh:mm:ss'?two(n/3600n)+':'+two(n/60n%60n):two(n/60n);
   return prefix+':'+two(n%60n)+(fraction?'.'+fraction:'');
  }
  return null;
 }
 return {kind,allowed,valid,defaults,normalize,move,format,types,dates,durations};
}
module.exports=createAuditColumnFormats();
