import { createOpencode } from "@opencode-ai/sdk"
import fs from "node:fs"; import os from "node:os"; import path from "node:path"
const dir = fs.mkdtempSync(path.join(os.tmpdir(), "loupe-cfg-"))
process.env.OPENCODE_CONFIG_DIR = dir
const { client, server } = await createOpencode({ port: 0 })
let ok=false, err=null
try {
  const s = (await client.session.create({ body: {} })).data.id
  const events = await client.event.subscribe()
  ;(async()=>{ for await (const ev of events.stream){ const p=ev.properties||{}
    if(ev.type==="message.part.delta"&&p.field==="text") ok=true
    if(ev.type==="session.error") err=JSON.stringify(p).slice(0,300) } })().catch(()=>{})
  await client.session.promptAsync({ path:{id:s}, body:{ model:{providerID:"openai",modelID:"gpt-5.5"}, agent:"build", parts:[{type:"text",text:"Reply with exactly OK"}] } })
  await new Promise(r=>setTimeout(r,12000))
} catch(e){ err=String(e).slice(0,300) }
console.log("[gpt55]", ok ? "✅ gpt-5.5 works under OPENCODE_CONFIG_DIR override" : ("❌ failed: "+err))
server.close(); fs.rmSync(dir,{recursive:true,force:true}); process.exit(0)
