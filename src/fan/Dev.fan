//
// Copyright (c) 2011, Andy Frank
// Licensed under the MIT License
//
// History:
//   6 Jun 2011  Andy Frank  Creation
//

using concurrent
using util
using web
using wisp

//////////////////////////////////////////////////////////////////////////
// DevRestarter
//////////////////////////////////////////////////////////////////////////

** DevRestarter
const class DevRestarter : Actor
{
  new make(ActorPool p, Type type, Int port) : super(p)
  {
    this.type = type
    this.port = port
  }

  ** Check if pods have been modified.
  Void checkPods() { send("verify").get(30sec) }

  override Obj? receive(Obj? msg)
  {
    if (msg == "verify")
    {
      map := Actor.locals["ts"] as Pod:DateTime
      if (map == null)
      {
        startProc
        Actor.locals["ts"] = update
      }
      else if (podsModified(map))
      {
        stopProc; startProc; Actor.sleep(2sec)
        Actor.locals["ts"] = update
      }
    }
    return null
  }

  ** Update pod modified timestamps.
  private Pod:DateTime update()
  {
    map := Pod:DateTime[:]
    Pod.list.each |p| { map[p] = podFile(p).modified }
    log.info("Update pod timestamps ($map.size pods)")
    return map
  }

  ** Return pod file for this Pod.
  private File podFile(Pod pod)
  {
    Env? env := Env.cur
    file := env.workDir + `_doesnotexist_`

    // walk envs looking for pod file
    while (!file.exists && env != null)
    {
      file = env.workDir + `lib/fan/${pod.name}.pod`
      env = env.parent
    }

    // verify exists and return
    if (!file.exists) throw Err("Pod file not found $pod.name")
    return file
  }

  ** Return true if any pods have been modified since startup.
  private Bool podsModified(Pod:DateTime map)
  {
    true == Pod.list.eachWhile |p|
    {
      if (podFile(p).modified > map[p])
      {
        log.info("$p.name pod has been modified")
        return true
      }
      return null
    }
  }

  ** Start DraftMod process.
  private Void startProc()
  {
    home := Env.cur.homeDir.osPath
    args := ["java", "-cp", "${home}/lib/java/sys.jar", "-Dfan.home=$home",
             "fanx.tools.Fan", "draft", "-port", "$port", "-proxy", type.qname]
    proc := Process(args).run

    Actor.locals["proc"] = proc
    log.info("Start external process")
  }

  ** Stop DraftMod process.
  private Void stopProc()
  {
    proc := Actor.locals["proc"] as Process
    if (proc == null) return
    proc.kill
    log.info("Stop external process")
  }

  const Type type
  const Int port
  const Log log := Log.get("draft")
}

//////////////////////////////////////////////////////////////////////////
// DevMod
//////////////////////////////////////////////////////////////////////////

** DevMod
const class DevMod : WebMod
{
  ** Constructor.
  new make(DevRestarter r)
  {
    this.restarter = r
    this.port = r.port
  }

  ** Target port to proxy requests to.
  const Int port

  ** DevRestarter instance.
  const DevRestarter restarter

  override Void onService()
  {
    // check pods
    restarter.checkPods

    // proxy request
    c := WebClient()
    c.followRedirects = false
    c.reqUri = `http://localhost:${port}${req.uri.relToAuth}`
    c.reqMethod = req.method
    req.headers.each |v,k|
    {
      if (k == "Host") return
      c.reqHeaders[k] = v
    }
    c.writeReq
    if (req.method == "POST")
      c.reqOut.writeBuf(req.in.readAllBuf)

    // proxy response
    c.readRes
    res.statusCode = c.resCode
    c.resHeaders.each |v,k| { res.headers[k] = v }
    res.out.writeBuf(c.resIn.readAllBuf).flush
    c.close
  }
}