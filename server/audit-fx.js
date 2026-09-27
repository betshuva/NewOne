"use strict";
// Verified Bank of Israel snapshot; the date stays visible when refresh fails.
const SOURCE='https://boi.org.il/PublicApi/GetExchangeRates';
let snapshot={rate:3.033,date:'2026-09-25',source:SOURCE},nextRefresh=0,pending;
function currentFx(){return {...snapshot};}
function parseFx(body){
 const usd=body?.exchangeRates?.find(row=>row.key==='USD');
 const rate=Number(usd?.currentExchangeRate)/Number(usd?.unit);
 const date=typeof usd?.lastUpdate==='string'?usd.lastUpdate.slice(0,10):'';
 if(!Number.isFinite(rate)||rate<=0||rate>100||!/^\d{4}-\d{2}-\d{2}$/.test(date)||!Number.isFinite(Date.parse(date))||Date.parse(date)>Date.now()+86400000)throw Error('Invalid exchange rate');
 return {rate,date,source:SOURCE};
}
async function refreshFx(fetcher=fetch){
 if(Date.now()<nextRefresh)return currentFx();
 if(pending)return pending;
 pending=(async()=>{try{
  const response=await fetcher(SOURCE,{signal:AbortSignal.timeout(3000)});
  if(!response.ok)throw Error('Exchange rate unavailable');
  const next=parseFx(await response.json());if(next.date>=snapshot.date)snapshot=next;
  nextRefresh=Date.now()+3600000;
 }catch{nextRefresh=Date.now()+300000;}finally{pending=null;}return currentFx();})();
 return pending;
}
module.exports={currentFx,refreshFx,parseFx};
