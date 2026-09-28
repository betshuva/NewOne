'use strict';
const columnFormats=require('./audit-column-formats');

const LEGACY_COLUMN_IDS = {
  operations: ['expand','created_at','action','kind','change_context','before_value','after_value','event_explanation','check_type','check_outcome','initiator_id','executor_id','recipient_id','target_type','source','status','reason_code','event_count','elapsed_ms','duration_ms','details'],
  events: ['created_at','kind','change_context','before_value','after_value','event_explanation','check_type','check_outcome','initiator_id','executor_id','recipient_id','source','status','target_type','reason_code','attempt','operation_id','elapsed_ms','duration_ms','details'],
};
const COLUMN_IDS = {"operations": ["expand", "created_at", "action", "kind", "step_index", "object_status", "operation_status", "status", "initiator_id", "initiator_identifier", "executor_id", "executor_identifier", "executor_type", "recipient_id", "recipient_identifier", "recipient_type", "dispatch_state", "dispatch_reason", "dispatch_code", "dispatch_delivery", "dispatch_sent_count", "dispatch_failed_count", "dispatch_message_type", "dispatch_content", "dispatch_file_name", "dispatch_message_id", "dispatch_recipients", "elapsed_ms", "duration_ms", "operation_total_tokens", "operation_cost_ils", "operation_usage_status", "input_tokens", "output_tokens", "cached_input_tokens", "total_tokens", "cost_ils", "usage_status", "usage_model", "fx_rate", "fx_date", "operation_input_tokens", "operation_output_tokens", "operation_reason", "operation_reason_code", "step_reason", "reason_code", "provider_calls_used", "provider_calls_limit", "change_context", "before_value", "after_value", "event_explanation", "check_type", "check_outcome", "person_count", "face_count", "confidence", "findings", "provider", "frame_index", "frame_timestamp", "cache_hit", "scan_image", "preview", "stopped_evidence", "target_type", "target_id", "source", "http_status", "affected_count", "attempt", "event_count", "operation_id", "event_id", "parent_event_id", "beforeText", "afterText", "beforeImage", "afterImage", "beforeVideo", "afterVideo", "beforeAudio", "afterAudio", "beforeDocument", "afterDocument", "beforeMen", "afterMen", "beforeWomen", "afterWomen", "beforeChildren", "afterChildren", "beforeNonHumanImages", "afterNonHumanImages", "beforeEnforceGeneralFilter", "afterEnforceGeneralFilter", "details"], "events": ["select", "created_at", "action", "kind", "object_status", "operation_status", "status", "initiator_id", "initiator_identifier", "executor_id", "executor_identifier", "executor_type", "recipient_id", "recipient_identifier", "recipient_type", "dispatch_state", "dispatch_reason", "dispatch_code", "dispatch_delivery", "dispatch_sent_count", "dispatch_failed_count", "dispatch_message_type", "dispatch_content", "dispatch_file_name", "dispatch_message_id", "dispatch_recipients", "elapsed_ms", "duration_ms", "operation_total_tokens", "operation_cost_ils", "operation_usage_status", "input_tokens", "output_tokens", "cached_input_tokens", "total_tokens", "cost_ils", "usage_status", "usage_model", "fx_rate", "fx_date", "operation_input_tokens", "operation_output_tokens", "operation_reason", "operation_reason_code", "step_reason", "reason_code", "provider_calls_used", "provider_calls_limit", "change_context", "before_value", "after_value", "event_explanation", "check_type", "check_outcome", "person_count", "face_count", "confidence", "findings", "provider", "frame_index", "frame_timestamp", "cache_hit", "scan_image", "preview", "stopped_evidence", "target_type", "target_id", "source", "http_status", "affected_count", "attempt", "operation_id", "event_id", "parent_event_id", "beforeText", "afterText", "beforeImage", "afterImage", "beforeVideo", "afterVideo", "beforeAudio", "afterAudio", "beforeDocument", "afterDocument", "beforeMen", "afterMen", "beforeWomen", "afterWomen", "beforeChildren", "afterChildren", "beforeNonHumanImages", "afterNonHumanImages", "beforeEnforceGeneralFilter", "afterEnforceGeneralFilter", "details"]};
const AUDIT_COLUMN_ORDER_SQL = `
CREATE TABLE IF NOT EXISTS audit_column_orders (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  mode text NOT NULL CHECK (mode IN ('operations','events')),
  column_order jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id,mode)
);
ALTER TABLE audit_column_orders ADD COLUMN IF NOT EXISTS column_widths jsonb NOT NULL DEFAULT '{}'::jsonb;
ALTER TABLE audit_column_orders ADD COLUMN IF NOT EXISTS column_formats jsonb NOT NULL DEFAULT '{}'::jsonb;`;

function registerAuditColumnOrderRoutes(app, { getPool, adminMiddleware }) {
  const route = (method,path,handler) => app[method](path,adminMiddleware,async(req,res) => {
    res.set('Cache-Control','no-store');
    if (!req.user?.id) return res.status(401).json({error:'Authentication required'});
    try { return await handler(req,res,await getPool()); }
    catch (error) {
      console.error('[audit-column-order] Request failed:',error.code || error.name);
      return res.status(503).json({error:'Column order is temporarily unavailable'});
    }
  });
  route('get','/api/admin/audit/column-order',async(req,res,db) => {
    const result=await db.query('SELECT mode,column_order,column_widths,column_formats FROM audit_column_orders WHERE user_id=$1',[req.user.id]);
    return res.json({orders:Object.fromEntries(result.rows.map(row=>[row.mode,row.column_order])),
      widths:Object.fromEntries(result.rows.map(row=>[row.mode,row.column_widths])),
      ...(req.query?.formats==='1'?{formats:Object.fromEntries(result.rows.map(row=>[row.mode,row.column_formats||{}]))}:{})});
  });
  route('put','/api/admin/audit/column-settings/:mode',async(req,res,db)=>{
    const mode=req.params.mode,order=req.body?.order,formats=req.body?.formats;
    const allowed=Object.hasOwn(COLUMN_IDS,mode)?COLUMN_IDS[mode]:null;
    if(!allowed||!Array.isArray(order)||order.length!==allowed.length||new Set(order).size!==allowed.length||order.some(key=>!allowed.includes(key))||
      !formats||typeof formats!=='object'||Array.isArray(formats)||Object.entries(formats).some(([key,f])=>!allowed.includes(key)||!columnFormats.valid(key,f)))
      return res.status(400).json({error:'Invalid column settings'});
    const normalized=columnFormats.normalize(formats,allowed);
    await db.query(`INSERT INTO audit_column_orders(user_id,mode,column_order,column_formats) VALUES($1,$2,$3::jsonb,$4::jsonb)
      ON CONFLICT(user_id,mode) DO UPDATE SET column_order=EXCLUDED.column_order,column_formats=EXCLUDED.column_formats,updated_at=now()`,
      [req.user.id,mode,JSON.stringify(order),JSON.stringify(normalized)]);
    return res.json({mode,order,formats:normalized});
  });
  route('put','/api/admin/audit/column-widths/:mode',async(req,res,db) => {
    const mode=req.params.mode,widths=req.body?.widths;
    const allowed=Object.hasOwn(COLUMN_IDS,mode) ? COLUMN_IDS[mode] : null;
    if (!allowed || !widths || typeof widths!=='object' || Array.isArray(widths) ||
        Object.entries(widths).some(([key,width])=>(!allowed.includes(key)&&!(mode==='operations'&&key==='step_total')) || !Number.isInteger(width) || width<48 || width>1200))
      return res.status(400).json({error:'Invalid column widths'});
    await db.query(`INSERT INTO audit_column_orders(user_id,mode,column_order,column_widths) VALUES($1,$2,$3::jsonb,$4::jsonb)
      ON CONFLICT(user_id,mode) DO UPDATE SET column_widths=EXCLUDED.column_widths,updated_at=now()`,
    [req.user.id,mode,JSON.stringify(allowed),JSON.stringify(widths)]);
    return res.json({mode,widths});
  });
  route('put','/api/admin/audit/column-order/:mode',async(req,res,db) => {
    const mode=req.params.mode;let order=req.body?.order;
    const allowed=Object.hasOwn(COLUMN_IDS,mode) ? COLUMN_IDS[mode] : null;
    if(allowed&&Array.isArray(order)&&!order.includes('stopped_evidence')&&order.includes('preview')){
      order=order.slice();order.splice(order.indexOf('preview')+1,0,'stopped_evidence');
    }
    if(allowed&&Array.isArray(order)&&!order.includes('object_status')&&order.includes('operation_status')){
      order=order.slice();order.splice(order.indexOf('operation_status'),0,'object_status');
    }
    if(allowed&&Array.isArray(order)&&!order.includes('scan_image')&&order.includes('preview')){
      order=order.slice();order.splice(order.indexOf('preview'),0,'scan_image');
    }
    // Keep old tabs compatible when the two step columns are merged; never hide duplicate IDs.
    if(mode==='operations'&&Array.isArray(order)&&order.filter(key=>key==='step_total').length===1)order=order.filter(key=>key!=='step_total');
    // Older tabs may still save the former layout. Add the new field beside its parent.
    if(mode==='operations'&&Array.isArray(order)&&!order.includes('kind')&&order.includes('action')){order=order.slice();order.splice(order.indexOf('action')+1,0,'kind');}
    if(allowed&&Array.isArray(order)&&order.includes('kind')){order=order.slice();let anchor='kind';for(const key of ['change_context','before_value','after_value','event_explanation']){if(!order.includes(key))order.splice(order.indexOf(anchor)+1,0,key);anchor=key;}}
    if(Array.isArray(order)){order=order.slice();if(mode==='operations'&&order.includes('initiator_id')&&!order.includes('executor_id'))order.splice(order.indexOf('initiator_id')+1,0,'executor_id');if(mode==='events'&&order.includes('executor_id')&&!order.includes('initiator_id'))order.splice(order.indexOf('executor_id'),0,'initiator_id');}
    if(allowed&&Array.isArray(order)){order=order.slice();if(mode==='events'&&!order.includes('duration_ms')&&order.includes('details'))order.splice(order.indexOf('details'),0,'duration_ms');if(!order.includes('elapsed_ms')&&order.includes('duration_ms'))order.splice(order.indexOf('duration_ms'),0,'elapsed_ms');}
    if(allowed&&Array.isArray(order)&&LEGACY_COLUMN_IDS[mode].every(key=>order.includes(key))){
      order=order.slice();for(const [index,key]of allowed.entries())if(!order.includes(key)){const previous=allowed[index-1];order.splice(previous&&order.includes(previous)?order.indexOf(previous)+1:0,0,key);}
    }
    if(allowed&&Array.isArray(order)&&allowed.filter(k=>!["operation_total_tokens", "operation_cost_ils", "operation_usage_status", "input_tokens", "output_tokens", "cached_input_tokens", "total_tokens", "cost_ils", "usage_status", "usage_model", "fx_rate", "fx_date", "operation_input_tokens", "operation_output_tokens"].includes(k)).every(k=>order.includes(k))){order=order.slice();for(const [i,key]of allowed.entries())if(!order.includes(key))order.splice(order.indexOf(allowed[i-1])+1,0,key);}
    if (!allowed || !Array.isArray(order) || order.length!==allowed.length ||
        new Set(order).size!==allowed.length || order.some(key=>!allowed.includes(key)))
      return res.status(400).json({error:'Invalid column order'});
    await db.query(`INSERT INTO audit_column_orders(user_id,mode,column_order) VALUES($1,$2,$3::jsonb)
      ON CONFLICT(user_id,mode) DO UPDATE SET column_order=EXCLUDED.column_order,updated_at=now()`,
    [req.user.id,mode,JSON.stringify(order)]);
    return res.json({mode,order});
  });
}

module.exports={AUDIT_COLUMN_ORDER_SQL,COLUMN_IDS,registerAuditColumnOrderRoutes};
