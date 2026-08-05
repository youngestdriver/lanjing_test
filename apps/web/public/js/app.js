// ========== State ==========
const AUTO_ADVANCE_KEY="quiz.autoAdvanceOnCorrect";
const S = {
  exams:[], currentExam:null, questions:[], states:[], stateMap:{}, sectionMap:{}, qIdx:0,
  answered:{}, selectedOptionsByQuestion:{}, answerPayloadByQuestion:{}, answerSyncState:{},
  examLoadToken:0, listLoadToken:0, timerByQuestion:{}, activeTimerId:null, timerHandle:null,
  autoAdvanceOnCorrect:localStorage.getItem(AUTO_ADVANCE_KEY)==="true",
  autoAdvanceHandle:null, navigationGeneration:0, suppressedExamStates:{}, abandonInFlight:{},
  lanEnabled:null,
  sessionGeneration:0, answerSyncToken:0, markSyncToken:0, abandonRequestToken:0,
  markSyncState:{}, quizStatusOwner:null, submitInFlight:false, quizCompleted:false,
  routeToken:0, examListLoaded:false,
};
const $ = s=>document.querySelector(s);
function $$(s){ return document.querySelectorAll(s); }

(function(){
  const savedTheme=localStorage.getItem("theme");
  if(savedTheme==="light"||savedTheme==="dark") document.documentElement.setAttribute("data-theme",savedTheme);
})();
function syncThemeControls(){
  const theme=document.documentElement.getAttribute("data-theme")==="dark"?"dark":"light";
  $$('[data-theme-choice]').forEach(button=>{
    const active=button.dataset.themeChoice===theme;
    button.classList.toggle("active",active);
    button.setAttribute("aria-pressed",String(active));
  });
}
function setTheme(theme){
  if(theme!=="light"&&theme!=="dark") return;
  document.documentElement.setAttribute("data-theme",theme);
  localStorage.setItem("theme",theme);
  syncThemeControls();
}
function toggleTheme() {
  const el=document.documentElement, cur=el.getAttribute("data-theme");
  setTheme(cur==="dark"?"light":"dark");
}
function syncAutoAdvanceControls(){
  $$('[data-auto-advance]').forEach(input=>{ input.checked=S.autoAdvanceOnCorrect; });
}
function cancelAutoAdvance(){
  if(S.autoAdvanceHandle) clearTimeout(S.autoAdvanceHandle);
  S.autoAdvanceHandle=null;
  S.navigationGeneration++;
}
function setAutoAdvance(enabled){
  S.autoAdvanceOnCorrect=Boolean(enabled);
  localStorage.setItem(AUTO_ADVANCE_KEY,String(S.autoAdvanceOnCorrect));
  if(!S.autoAdvanceOnCorrect) cancelAutoAdvance();
  syncAutoAdvanceControls();
}
const LAN_HINT_ENABLED="开启后，同一局域网的设备可通过本机 IP 访问本服务";
const LAN_HINT_DISABLED="已关闭，局域网设备将无法访问本服务";
const LAN_HINT_ENV_OVERRIDE="绑定地址由 HOST 环境变量控制，本开关控制访问白名单";
async function syncLanControl(){
  const toggle=$('[data-lan-toggle]');
  const hint=$('[data-lan-hint]');
  if(!toggle||!hint) return;
  if(S.lanEnabled===null){
    const r=await api("/api/settings");
    if(r.lanEnabled!==undefined){
      S.lanEnabled=r.lanEnabled;
      toggle.checked=r.lanEnabled;
      toggle.disabled=false;
      hint.textContent=r.envHost?LAN_HINT_ENV_OVERRIDE:(r.lanEnabled?LAN_HINT_ENABLED:LAN_HINT_DISABLED);
    }else{
      toggle.disabled=true;
      hint.textContent="无法读取服务器设置";
    }
  }else{
    toggle.checked=S.lanEnabled;
  }
}
async function setLanAccess(enabled){
  const toggle=$('[data-lan-toggle]');
  const hint=$('[data-lan-hint]');
  if(!toggle||!hint) return;
  toggle.disabled=true;
  hint.textContent="保存中…";
  const r=await api("/api/settings",{method:"POST",body:JSON.stringify({lanEnabled:enabled})});
  toggle.disabled=false;
  if(r.lanEnabled!==undefined){
    S.lanEnabled=r.lanEnabled;
    toggle.checked=r.lanEnabled;
    hint.textContent=r.envHost?LAN_HINT_ENV_OVERRIDE:(r.lanEnabled?LAN_HINT_ENABLED:LAN_HINT_DISABLED);
  }else{
    toggle.checked=S.lanEnabled===true;
    hint.textContent=r.error||"保存失败，请重试";
  }
}
function showPage(id){
  if(id!=="#quizPage"){
    cancelAutoAdvance();
    stopQuestionTimer();
    updateQuestionTimerDisplay(60,"paused");
  }
  $$(".page").forEach(p=>p.classList.remove("active"));
  $(id).classList.add("active");
}

function isCurrentExamOperation(examId,loadToken){
  return loadToken===S.examLoadToken
    && String(S.currentExam?.examInfoId||"")===String(examId||"");
}

function canUpdateQuiz(examId,loadToken){
  return isCurrentExamOperation(examId,loadToken)
    && !S.quizCompleted
    && $("#quizPage").classList.contains("active");
}

function formatQuestionTimer(seconds){
  const s=Math.max(0,seconds);
  const mm=String(Math.floor(s/60)).padStart(2,"0");
  const ss=String(s%60).padStart(2,"0");
  return `${mm}:${ss}`;
}
function updateQuestionTimerDisplay(seconds,mode="active"){
  const timer=$("#questionTimer");
  const wrap=$("#questionTimerWrap");
  if(timer) timer.textContent=formatQuestionTimer(seconds);
  if(wrap){
    wrap.classList.toggle("paused",mode==="paused");
    wrap.classList.toggle("expired",mode==="expired");
  }
}
function stopQuestionTimer(){
  if(S.timerHandle){
    clearInterval(S.timerHandle);
    S.timerHandle=null;
  }
  S.activeTimerId=null;
}
function startQuestionTimer(questionId,isAnswered){
  if(isAnswered){
    stopQuestionTimer();
    updateQuestionTimerDisplay(60,"paused");
    return;
  }
  if(S.timerByQuestion[questionId] == null) S.timerByQuestion[questionId]=60;
  updateQuestionTimerDisplay(S.timerByQuestion[questionId],S.timerByQuestion[questionId]===0?"expired":"active");
  if(S.activeTimerId===questionId && S.timerHandle) return;
  stopQuestionTimer();
  S.activeTimerId=questionId;
  if(S.timerByQuestion[questionId]===0) return;
  S.timerHandle=setInterval(()=>{
    const q=S.questions[S.qIdx];
    const st=S.stateMap[questionId]||{};
    const stillCurrent=q&&q._id===questionId;
    const nowAnswered=S.answered[questionId]||st.state!=="unanswered";
    if(!stillCurrent||nowAnswered){
      stopQuestionTimer();
      if(nowAnswered) updateQuestionTimerDisplay(60,"paused");
      return;
    }
    S.timerByQuestion[questionId]=Math.max(0,(S.timerByQuestion[questionId]??60)-1);
    const left=S.timerByQuestion[questionId];
    updateQuestionTimerDisplay(left,left===0?"expired":"active");
    if(left===0) stopQuestionTimer();
  },1000);
}

function resetQuizView(title="Loading..."){
  cancelAutoAdvance();
  stopQuestionTimer();
  S.currentExam=null;
  S.questions=[];
  S.states=[];
  S.stateMap={};
  S.sectionMap={};
  S.qIdx=0;
  S.answered={};
  S.selectedOptionsByQuestion={};
  S.answerPayloadByQuestion={};
  S.answerSyncState={};
  S.markSyncState={};
  S.timerByQuestion={};
  S.submitInFlight=false;
  S.quizCompleted=false;
  $("#quizTitle").textContent=title;
  $("#qProgress").textContent="";
  $("#qSection").textContent="";
  $("#sectionTabs").innerHTML="";
  $("#answerGrid").innerHTML="";
  $("#statsBar").innerHTML="";
  setQuizStatus("");
  const progress=$("#duoProgressBarFill");
  if(progress) progress.style.width="0%";
  updateQuestionTimerDisplay(60, "paused");
}

function navigateTo(path){
  history.pushState(null,"",path);
  route();
}
const HOME_PATHS={exams:"/",practice:"/practice",profile:"/profile"};
const HOME_HEADINGS={exams:"examListHeading",practice:"practiceHeading",profile:"profileHeading"};
function focusHomeHeading(tab){
  document.getElementById(HOME_HEADINGS[tab]||HOME_HEADINGS.exams)?.focus({preventScroll:true});
}
function activateHomeTab(tab,{historyMode="none",refresh=false}={}){
  const selected=HOME_PATHS[tab]?tab:"exams";
  if($("#quizPage").classList.contains("active")){
    S.examLoadToken++;
    S.listLoadToken++;
    S.examListLoaded=false;
    resetQuizView("题目");
  }
  showPage("#appPage");
  $$('[data-home-tab]').forEach(link=>{
    const active=link.dataset.homeTab===selected;
    link.classList.toggle("active",active);
    if(active) link.setAttribute("aria-current","page");
    else link.removeAttribute("aria-current");
  });
  $$('[data-home-view]').forEach(view=>{
    const active=view.dataset.homeView===selected;
    view.classList.toggle("active",active);
    view.hidden=!active;
  });
  syncThemeControls();
  syncAutoAdvanceControls();
  syncLanControl();

  const heading=document.getElementById(HOME_HEADINGS[selected]);
  document.title=`${heading?.textContent||"蓝鲸助手"} · 蓝鲸助手`;
  const routeStatus=$("#homeRouteStatus");
  if(routeStatus) routeStatus.textContent=`已打开${heading?.textContent||"首页"}`;

  const path=HOME_PATHS[selected];
  if(historyMode==="push"&&location.pathname!==path) history.pushState(null,"",path);
  else if(historyMode==="replace"&&location.pathname!==path) history.replaceState(null,"",path);

  if(selected==="exams"&&(refresh||!S.examListLoaded)) loadExams();
}
function openHomeTab(tab,event){
  event?.preventDefault();
  S.routeToken++;
  activateHomeTab(tab,{historyMode:"push"});
  focusHomeHeading(HOME_PATHS[tab]?tab:"exams");
}
function isExamListActive(){
  return $("#appPage").classList.contains("active")
    && $('[data-home-view="exams"]').classList.contains("active");
}
function route(){
  const p=location.pathname;
  const routeToken=++S.routeToken;
  api("/api/status").then(r=>{
    if(routeToken!==S.routeToken) return;
    if(r.error){
      history.replaceState(null,"","/login");
      showPage("#loginPage");
      document.title="登录 · 蓝鲸助手";
      showLoginErr(r.error);
      return;
    }
    if(!r.loggedIn){
      if(p!=="/login") history.replaceState(null,"","/login");
      showPage("#loginPage");
      document.title="登录 · 蓝鲸助手";
    } else {
      const quizRoute=p.match(/^\/quiz\/(\d+)$/);
      if(quizRoute){
        const id=parseInt(quizRoute[1]);
        if(id&&S.currentExam?.examInfoId!==String(id)) enterExam(id,false);
        else if(!S.currentExam) enterExam(id,false);
        else showPage("#quizPage");
      } else {
        const tab=p==="/practice"?"practice":p==="/profile"?"profile":"exams";
        const canonicalPath=HOME_PATHS[tab];
        activateHomeTab(tab,{
          historyMode:p===canonicalPath?"none":"replace",
          refresh:tab==="exams"&&!S.examListLoaded,
        });
      }
    }
  });
}
window.addEventListener("popstate",route);

// ========== API ==========
async function api(url,opts={}){
  const requestSessionGeneration=S.sessionGeneration;
  const requestExamLoadToken=S.examLoadToken;
  try{
    const r=await fetch(url,{headers:{"Content-Type":"application/json"},...opts});
    const contentType=r.headers.get("content-type")||"";
    let data;
    if(contentType.includes("application/json")) data=await r.json();
    else{
      const text=await r.text();
      data={error:text.trim()||`请求失败（HTTP ${r.status}）`};
    }
    if(r.status===401){
      if(url==="/api/login") return {error:data?.error||"登录失败",status:401};
      if(requestSessionGeneration!==S.sessionGeneration||requestExamLoadToken!==S.examLoadToken){
        return {error:data?.error||"会话已失效",status:401,stale:true};
      }
      S.routeToken++;
      S.sessionGeneration++;
      sessionStorage.clear();
      S.examLoadToken++;
      S.submitInFlight=false;
      resetQuizView("题目");
      clearLoginCredentials();
      history.replaceState(null,"","/login");
      showPage("#loginPage");
      document.title="登录 · 蓝鲸助手";
      showLoginErr("会话已失效，请重新登录");
      return {error:"会话已失效，请重新登录",status:401};
    }
    if(!r.ok) return {error:data?.error||`请求失败（HTTP ${r.status}）`,status:r.status};
    if(!data||typeof data!=="object") return {error:"服务器返回了无法识别的响应"};
    return data;
  }catch(error){
    return {error:error instanceof Error?`网络请求失败：${error.message}`:"网络请求失败",networkError:true};
  }
}

function showErrorState(container,message,actions=[]){
  container.innerHTML='<div class="error-state"><p></p><div class="error-state-actions"></div></div>';
  container.querySelector("p").textContent=message||"操作失败";
  const actionBox=container.querySelector(".error-state-actions");
  for(const action of actions){
    const button=document.createElement("button");
    button.type="button";
    button.textContent=action.label;
    button.addEventListener("click",action.run);
    actionBox.appendChild(button);
  }
}

function setQuizStatus(message,kind="info",action=null,owner="general"){
  const status=$("#quizStatus");
  if(!status) return;
  S.quizStatusOwner=message?owner:null;
  status.className="quiz-status";
  status.replaceChildren();
  if(!message) return;
  status.classList.add("visible");
  if(kind==="error") status.classList.add("error");
  const text=document.createElement("span");
  text.textContent=message;
  status.appendChild(text);
  if(action){
    const button=document.createElement("button");
    button.type="button";
    button.textContent=action.label;
    button.addEventListener("click",action.run);
    status.appendChild(button);
  }
}

function escapeHTML(value){
  return String(value??"").replace(/[&<>"']/g,char=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"})[char]);
}

// ========== Login ==========
function clearLoginCredentials(){
  if($("#phone")) $("#phone").value="";
  if($("#pwd")) $("#pwd").value="";
}

async function doLogin(){
  const ph=$("#phone").value.trim(), pw=$("#pwd").value;
  if(!ph||!pw) return showLoginErr("请输入手机号和密码");
  showLoginErr("");
  const r=await api("/api/login",{method:"POST",body:JSON.stringify({phone:ph,password:pw})});
  if(r.error) return showLoginErr(r.error);
  S.sessionGeneration++;
  $("#pwd").value="";
  S.exams=[];
  S.examListLoaded=false;
  S.suppressedExamStates={};
  S.abandonInFlight={};
  abandonState={};
  navigateTo("/");
}
function showLoginErr(m){ const e=$("#loginErr"); e.textContent=m; e.style.display=m?"block":"none"; }
async function doLogout(){
  await api("/api/logout",{method:"POST",body:"{}"});
  S.sessionGeneration++;
  sessionStorage.clear();
  S.examLoadToken++;
  S.listLoadToken++;
  S.exams=[];
  S.examListLoaded=false;
  S.suppressedExamStates={};
  S.abandonInFlight={};
  abandonState={};
  resetQuizView("题目");
  clearLoginCredentials();
  navigateTo("/login");
}

// ========== Exam List ==========
async function loadExams(){
  const loadToken=++S.listLoadToken;
  const el=$("#examList"); el.innerHTML='<div class="loading"><div class="spinner"></div><div>加载中...</div></div>';
  const r=await api("/api/exams");
  if(loadToken!==S.listLoadToken) return;
  if(r.error){
    S.examListLoaded=false;
    showErrorState(el,r.error,[{label:"重新加载",run:()=>loadExams()}]);
    return;
  }
  const filtered=QuizCore.filterSuppressedExams(r.exams,S.suppressedExamStates);
  S.suppressedExamStates=filtered.suppressed;
  S.exams=filtered.exams;
  S.examListLoaded=true;
  renderExamList(S.exams);
}

function renderExamList(exams){
  const el=$("#examList");
  // Filter out 常识判断
  exams=exams.filter(e=>!e.name.includes("常识判断"));
  const grouped={};
  for(const e of exams) (grouped[e.style]??=[]).push(e);
  const keys=Object.keys(grouped);
  keys.sort((a,b)=>{if(a.includes("机考题库"))return -1;if(b.includes("机考题库"))return 1;return 0;});
  if(!keys.length){
    el.innerHTML='<div class="loading">当前没有可用试卷</div>';
    return;
  }
  let html="";
  for(const k of keys){
    html+=`<div class="category"><h3>${escapeHTML(k)}</h3>`;
    for(const e of grouped[k]){
      const ml={0:"模拟考试",1:"MOCK",2:"练习"}[e.practiceMode]??"?";
      const tl=e.totalTime===0?"不限时":`${e.totalTime}分钟`;
      const sl=e.wfs===1?'<span class="badge badge-new">新试卷</span>':'<span class="badge badge-cont">继续考试</span>';
      const mb=`<span class="badge ${e.practiceMode===0?'badge-exam':'badge-drill'}">${ml}</span>`;
      const examName=escapeHTML(e.name);
      html+=`<div class="exam-card" id="card-${e.id}">
        <div class="exam-card-inner">
          <button type="button" class="exam-card-main" onclick="enterExam(${e.id},${e.wfs===1})" aria-label="打开试卷：${examName}">
            <span class="card-info">
              <span class="name"><span style="display:block;margin-bottom:4px;line-height:1;">${sl}</span>${examName}</span>
              <span class="meta">${mb} | ${tl}</span>
            </span>
          </button>
          <button type="button" class="card-dots" onclick="toggleAbandon(${e.id})" aria-label="试卷操作：${examName}" aria-expanded="false" aria-controls="exam-action-${e.id}">⋯</button>
        </div>
        <button type="button" class="card-abandon" id="exam-action-${e.id}" data-exam-name="${examName}" onclick="abandonExam(${e.id})" aria-label="放弃考试：${examName}">放弃<br>考试</button></div>`;
    }
    html+=`</div>`;
  }
  el.innerHTML=html;
}

// ========== Enter Exam ==========
async function enterExam(id,isNew){
  S.routeToken++;
  S.listLoadToken++;
  S.examListLoaded=false;
  const loadToken=++S.examLoadToken;
  const exam=S.exams.find(e=>String(e.id)===String(id));
  showPage("#quizPage");
  $("#quizPage").classList.add("loading-quiz");
  document.title=`${exam?.name||"答题"} · 蓝鲸助手`;
  const routeStatus=$("#homeRouteStatus");
  if(routeStatus) routeStatus.textContent="";
  if(location.pathname!=="/quiz/"+id) history.pushState(null,"","/quiz/"+id);
  resetQuizView(exam?.name||"Loading...");
  const sc=$("#quizScroll");
  sc.innerHTML='<div class="q-block" id="qBlock"><div class="loading"><div class="spinner"></div><div>'+(isNew?'初始化...':'加载中...')+'</div></div></div>';
  const r=await api(`/api/exams/${id}/enter`,{method:"POST"});
  if(loadToken!==S.examLoadToken) return;
  if(r.error){
    showErrorState(sc,r.error,[
      {label:"重试",run:()=>enterExam(id,isNew)},
      {label:"返回列表",run:()=>showExamList()},
    ]);
    return;
  }
  S.currentExam=r; S.sectionMap=r.sections||{};
  sc.innerHTML='<div class="q-block" id="qBlock"><div class="loading"><div class="spinner"></div><div>加载题目...</div></div></div>';
  const qr=await api(`/api/exams/${id}/questions`);
  if(loadToken!==S.examLoadToken) return;
  if(qr.error){
    showErrorState(sc,qr.error,[
      {label:"重试",run:()=>enterExam(id,isNew)},
      {label:"返回列表",run:()=>showExamList()},
    ]);
    return;
  }
  S.questions=qr.questions; S.states=qr.states;
  // Build state map
  S.stateMap={};
  for(const s of S.states) S.stateMap[s.questionsId]=s;
  // Track answered: already-answered questions
  S.answered={};
  S.selectedOptionsByQuestion={};
  for(const q of S.questions){
    const previous=QuizCore.normalizeSelection(q._previousAnswers||QuizCore.parsePreviousAnswers(q.test_ans));
    if(previous.length) S.selectedOptionsByQuestion[q._id]=previous;
  }
  for(const s of S.states){
    if(s.state!=="unanswered") S.answered[s.questionsId]=true;
  }
  // Start at first unanswered, or first question
  S.qIdx=0;
  for(let i=0;i<S.states.length;i++){
    if(S.states[i].state==="unanswered"){ S.qIdx=i; break; }
  }
  renderQuiz();
}

// ========== Render Quiz ==========
function renderQuiz(){
  const exam=S.exams.find(e=>String(e.id)===String(S.currentExam.examInfoId));
  $("#quizTitle").textContent=exam?.name||"题目";
  renderAnswerGrid();
  renderSectionTabs();
  renderStatsBar();
  renderQuestion();
  $("#quizPage").classList.remove("loading-quiz");
}

function getOptionLetters(question){
  return ["A","B","C","D"].filter((_,index)=>Boolean(question[`answer${index+1}`]));
}

function getSelectedOptions(question){
  const available=new Set(getOptionLetters(question));
  return QuizCore.normalizeSelection(S.selectedOptionsByQuestion[question._id])
    .filter(letter=>available.has(letter));
}

function getSelectedOption(question){
  return getSelectedOptions(question)[0]||null;
}

function highlightSelectedOption(letter){
  const q=S.questions[S.qIdx];
  if(S.quizCompleted||!q||S.answered[q._id]) return;
  if(!getOptionLetters(q).includes(letter)) return;
  S.selectedOptionsByQuestion[q._id]=q._isMulti
    ?QuizCore.toggleSelection(getSelectedOptions(q),letter)
    :[letter];
  const selected=new Set(getSelectedOptions(q));
  $$("#qBlock .opt-row").forEach(row=>{
    const isSelected=selected.has(row.dataset.opt);
    row.classList.toggle("selected",isSelected);
    row.querySelector(".opt-dot, .opt-btn")?.classList.toggle("sel",isSelected);
  });
  const confirm=$("#confirmSelectionBtn");
  if(confirm) confirm.disabled=selected.size===0;
}

function clearSelectedOption(){
  const q=S.questions[S.qIdx];
  if(S.quizCompleted||!q||S.answered[q._id]) return;
  delete S.selectedOptionsByQuestion[q._id];
  $$("#qBlock .opt-row").forEach(row=>{
    row.classList.remove("selected");
    row.querySelector(".opt-dot, .opt-btn")?.classList.remove("sel");
  });
  const confirm=$("#confirmSelectionBtn");
  if(confirm) confirm.disabled=true;
}

function goToQuestion(index){
  if(S.quizCompleted||index<0||index>=S.questions.length||index===S.qIdx) return;
  cancelAutoAdvance();
  const direction=index>S.qIdx?1:-1;
  S.qIdx=index;
  renderSectionTabs();
  renderQuestion(direction);
}

function scheduleAutoAdvance(questionId){
  if(S.quizCompleted||!S.autoAdvanceOnCorrect||S.questions[S.qIdx]?._id!==questionId) return;
  if(S.autoAdvanceHandle) clearTimeout(S.autoAdvanceHandle);
  const generation=S.navigationGeneration;
  S.autoAdvanceHandle=setTimeout(()=>{
    S.autoAdvanceHandle=null;
    if(generation!==S.navigationGeneration||S.questions[S.qIdx]?._id!==questionId) return;
    const next=QuizCore.nextUnansweredIndex(S.states,S.qIdx);
    if(next>=0) goToQuestion(next);
  },1200);
}

function handleOptionClick(letter){
  const q=S.questions[S.qIdx];
  if(S.quizCompleted||!q||S.answered[q._id]) return;
  if(q._isMulti) highlightSelectedOption(letter);
  else submitSelection([letter]);
}

function confirmMultiSelection(){
  const q=S.questions[S.qIdx];
  if(S.quizCompleted||!q||!q._isMulti||S.answered[q._id]) return;
  const selected=getSelectedOptions(q);
  if(selected.length) submitSelection(selected);
}

function renderQuestion(direction=0){
  if(S.quizCompleted) return;
  const q=S.questions[S.qIdx];
  if(!q) return;
  const st=S.stateMap[q._id]||{};
  const isAnswered=S.answered[q._id]||st.state!=="unanswered";
  const selectedOptions=getSelectedOptions(q);
  const selectedSet=new Set(selectedOptions);

  // Progress
  $("#qProgress").textContent=`第 ${S.qIdx+1} / ${S.questions.length} 题`;
  $("#qSection").textContent=st.section||"";

  // Update Duolingo progress bar
  const duoProgressBarFill = document.getElementById("duoProgressBarFill");
  if(duoProgressBarFill) {
    const percent = S.questions.length ? ((S.qIdx + 1) / S.questions.length) * 100 : 0;
    duoProgressBarFill.style.width = percent + "%";
  }

  startQuestionTimer(q._id,isAnswered);

  // Build question HTML
  // Detect short-answer options (logic/推理 type) → horizontal layout
  const map=["A","B","C","D"];
  const optTexts=[];
  for(let i=1;i<=4;i++) if(q[`answer${i}`]) optTexts.push(q[`answer${i}`].replace(/<[^>]+>/g,"").trim());
  const isCompact=optTexts.length===4 && optTexts.every(t=>t.length<=2);

  let html=`<div class="q-num">`;
  if(st.state==="right") html+=`✅ 已答对`;
  else if(st.state==="error") html+=`❌ 已答错`;
  else html+=`⬜ 未作答`;
  html+=` <span class="badge-q">第 ${st.num||(S.qIdx+1)} 题</span>`;
  if(q._isMulti) html+=` <span class="badge-q badge-multi">多选</span>`;
  const isMarked = st.marked;
  const markPending=S.markSyncState[q._id]?.status==="pending";
  html+=` <button class="btn-mark${isMarked?' marked':''}" onclick="event.stopPropagation();toggleMark('${q._id}')" ${markPending?'disabled title="正在同步标记"':''}>${markPending?'正在同步…':isMarked?'🔖 已标记':'🔖 标记'}</button>`;
  html+=`</div>`;
  html+=`<div class="q-text">${q.question||""}</div>`;

  // Options — horizontal row if compact (short answers only), else vertical stack
  if(isCompact) html+=`<div class="options row">`;
  else html+=`<div class="options">`;

  for(let i=1;i<=4;i++){
    if(!q[`answer${i}`]) continue;
    const l=map[i-1];
    const isCorrect=q._answers.includes(l);
    let cls="opt-row";
    if(isCompact) cls+=" compact";
    if(selectedSet.has(l)) cls+=" selected";
    if(isAnswered){
      cls+=" answered";
      if(isCorrect) cls+=" correct";
      else if(selectedSet.has(l)) cls+=" wrong";
    }
    const multiType=q._isMulti?"opt-btn":"opt-dot";
    html+=`<div class="${cls}" data-opt="${l}" onclick="${isAnswered?'':'handleOptionClick(\''+l+'\')'}">
      <div class="${multiType}${selectedSet.has(l)?' sel':''}">${q._isMulti?'':l}</div>
      <div>${q[`answer${i}`]}</div></div>`;
  }
  html+=`</div>`;
  if(q._isMulti&&!isAnswered){
    html+=`<button id="confirmSelectionBtn" class="confirm-answer" onclick="confirmMultiSelection()" ${selectedOptions.length?'':'disabled'}>提交多选答案</button>`;
  }

  const syncState=S.answerSyncState[q._id];
  if(syncState?.status==="pending"){
    html+='<div class="sync-status">正在同步答案…</div>';
  }else if(syncState?.status==="error"){
    html+=`<div class="sync-status error">${escapeHTML(syncState.message)}<button onclick="retryAnswerSync('${q._id}')">重新同步</button></div>`;
  }

  // Explanation (only for answered questions)
  html+=`<div class="explain" id="explainBox">`;
  if(isAnswered){
    const wasRight=st.state==="right";
    html+=`<div class="ex-title">${wasRight?'✅ 回答正确':'❌ 回答错误！正确答案是：'+q._answers.join('、')}</div>`;
    if(!wasRight && q._answerHtml) html+=`<div class="ex-answer">${q._answerHtml}</div>`;
    if(q._analysis) html+=`<div class="ex-analysis">${q._analysis}</div>`;
  }
  html+=`</div>`;

  const qBlockEl=$("#qBlock");
  qBlockEl.innerHTML=html;
  if(direction){
    // Ease in the new question from the right (next) or left (previous).
    qBlockEl.classList.remove("slide-next","slide-prev");
    void qBlockEl.offsetWidth;
    qBlockEl.classList.add(direction>0?"slide-next":"slide-prev");
  }
  if(isAnswered){
    const box=$("#explainBox");
    box.classList.add("show");
    box.classList.add(st.state==="right"?"correct-explain":"wrong-explain");
  }

  // Scroll to top
  $("#quizScroll").scrollTop=0;

  // After answering, let content flow naturally
  const questionBlock=$("#qBlock");
  if(isAnswered) questionBlock.classList.add("answered-mode");
  else questionBlock.classList.remove("answered-mode");

  // Update answer grid highlight
  renderAnswerGrid();
}

async function submitSelection(letters){
  const q=S.questions[S.qIdx];
  if(S.quizCompleted||!q) return;
  const st=S.stateMap[q._id]||{};
  if(S.answered[q._id]) return; // already answered

  const selected=QuizCore.normalizeSelection(letters);
  if(!selected.length) return;
  const isCorrect=QuizCore.selectionsEqual(selected,q._answers);
  const submissionGeneration=S.navigationGeneration;
  S.selectedOptionsByQuestion[q._id]=selected;
  S.answered[q._id]=true;
  stopQuestionTimer();
  updateQuestionTimerDisplay(60,"paused");

  // Update state
  st.state=isCorrect?"right":"error";
  S.stateMap[q._id]=st;

  const payload={
    testId:q._id,
    testAns:QuizCore.encodeAnswers(selected),
    correct:isCorrect,
  };
  S.answerPayloadByQuestion[q._id]=payload;
  S.answerSyncState[q._id]={status:"pending"};
  renderQuestion();
  renderStatsBar();

  const synced=await syncAnswer(q._id);
  if(synced&&isCorrect&&submissionGeneration===S.navigationGeneration){
    scheduleAutoAdvance(q._id);
  }
}

async function syncAnswer(questionId){
  const payload=S.answerPayloadByQuestion[questionId];
  const examId=S.currentExam?.examInfoId;
  if(!payload||!examId) return false;
  const loadToken=S.examLoadToken;
  const requestToken=++S.answerSyncToken;
  S.answerSyncState[questionId]={status:"pending",requestToken};
  if(S.questions[S.qIdx]?._id===questionId) renderQuestion();
  renderStatsBar();
  const result=await api(`/api/exams/${examId}/answer`,{
    method:"POST",
    body:JSON.stringify(payload),
  });
  if(!canUpdateQuiz(examId,loadToken)
    ||S.answerPayloadByQuestion[questionId]!==payload
    ||S.answerSyncState[questionId]?.requestToken!==requestToken) return false;
  if(result.error||result.success!==true){
    S.answerSyncState[questionId]={
      status:"error",
      message:result.error||"答案未能同步到上游，请重试",
    };
    if(S.questions[S.qIdx]?._id===questionId) renderQuestion();
    renderStatsBar();
    return false;
  }
  S.answerSyncState[questionId]={status:"synced"};
  if(S.questions[S.qIdx]?._id===questionId) renderQuestion();
  renderStatsBar();
  return true;
}

async function retryAnswerSync(questionId){
  if(S.answerSyncState[questionId]?.status==="pending") return;
  const payload=S.answerPayloadByQuestion[questionId];
  const loadToken=S.examLoadToken;
  const submissionGeneration=S.navigationGeneration;
  const synced=await syncAnswer(questionId);
  if(synced
    &&payload?.correct
    &&loadToken===S.examLoadToken
    &&submissionGeneration===S.navigationGeneration
    &&S.answerPayloadByQuestion[questionId]===payload) scheduleAutoAdvance(questionId);
}

async function toggleMark(qId){
  if(S.quizCompleted) return;
  const st = S.stateMap[qId];
  if(!st||S.markSyncState[qId]?.status==="pending") return;
  const newMark = !st.marked;
  const requestToken=++S.markSyncToken;
  S.markSyncState[qId]={status:"pending",requestToken};
  st.marked = newMark;

  // Immediately update UI (optimistic)
  renderQuestion();
  renderAnswerGrid();
  renderStatsBar();

  const examId = S.currentExam.examInfoId;
  const loadToken = S.examLoadToken;
  const r = await api(`/api/exams/${examId}/mark`, {
    method: "POST",
    body: JSON.stringify({ testId: qId, isMark: newMark }),
  });
  if(!canUpdateQuiz(examId,loadToken)||S.markSyncState[qId]?.requestToken!==requestToken) return;
  delete S.markSyncState[qId];
  if (r.error||r.success!==true) {
    // Revert on failure
    st.marked = !newMark;
    renderQuestion();
    renderAnswerGrid();
    setQuizStatus(r.error||"题目标记未能同步，请重试","error",null,"mark");
  }else{
    renderQuestion();
    renderAnswerGrid();
    if(S.quizStatusOwner==="mark") setQuizStatus("");
  }
  renderStatsBar();
}

// ========== Sidebar ==========
function renderAnswerGrid(){
  const grid=$("#answerGrid");
  // Filter by active section tab
  const activeTab=$("#sectionTabs .sidebar-tab.active");
  let filtered=S.states;
  if(activeTab){
    const tabTitle=activeTab.textContent.trim();
    const fullKey=Object.keys(S.sectionMap).find(k=>k.startsWith(tabTitle));
    if(fullKey) filtered=S.states.filter(s=>s.section===fullKey);
  }
  grid.innerHTML=filtered.map((s)=>{
    const i=S.states.indexOf(s);
    let cls="answer-dot";
    if(s.state==="right") cls+=" done";
    else if(s.state==="error") cls+=" wrong-dot";
    if(i===S.qIdx) cls+=" cur";
    if(s.marked) cls+=" marked-dot";
    return `<div class="${cls}" onclick="goToQuestion(${i})" title="第${s.num}题${s.marked?' (已标记)':''}">${s.num}</div>`;
  }).join("");
  // Auto-scroll to current dot
  setTimeout(()=>{
    const cur=grid.querySelector(".cur");
    if(cur) {
      const gridLeft = grid.getBoundingClientRect().left;
      const curLeft = cur.getBoundingClientRect().left;
      const scrollOffset = curLeft - gridLeft - (grid.clientWidth / 2) + (cur.clientWidth / 2);
      grid.scrollBy({ left: scrollOffset, behavior: "smooth" });
    }
  },50);
}

function renderSectionTabs(){
  const tabs=$("#sectionTabs");
  const keys=Object.keys(S.sectionMap);
  if(keys.length<=1){ tabs.innerHTML=""; return; }
  // Auto-select tab based on current question's section
  const curQ=S.states[S.qIdx];
  const curSection=curQ?.section||"";
  tabs.innerHTML=keys.map(k=>{
    const short=k.replace(/\(.*/,"");
    const active=curSection===k;
    return `<button type="button" class="sidebar-tab ${active?'active':''}" data-section="${escapeHTML(k)}" onclick="jumpToSection(this.dataset.section,this)">${escapeHTML(short)}</button>`;
  }).join("");
}

function renderStatsBar(){
  const sts=S.states, r=sts.filter(s=>s.state==="right").length, e=sts.filter(s=>s.state==="error").length, u=sts.filter(s=>s.state==="unanswered").length;
  const sidebar=document.querySelector('.quiz-sidebar');
  const isCollapsed=sidebar?.classList.contains('collapsed');
  const syncStates=Object.values(S.answerSyncState);
  const hasPendingSync=syncStates.some(state=>state?.status==="pending");
  const hasPendingMark=Object.values(S.markSyncState).some(state=>state?.status==="pending");
  const hasSyncError=syncStates.some(state=>state?.status==="error");
  const hasPendingWrite=hasPendingSync||hasPendingMark;
  const submitDisabled=S.submitInFlight||S.quizCompleted||hasPendingWrite;
  const submitLabel=S.quizCompleted?"已交卷":S.submitInFlight?"提交中…":hasPendingWrite?"同步中…":hasSyncError?"先同步答案":"交卷";
  const submitTitle=hasPendingWrite?"请等待答案和标记同步完成":hasSyncError?"请先重新同步失败的答案":"";
  $("#statsBar").innerHTML=`<span>✅<span class="s-green">${r}</span> ❌<span class="s-red">${e}</span> ⬜${u}</span>
    <button onclick="toggleSidebarCollapse()" class="sidebar-collapse-btn">${isCollapsed?'▲ 展开':'▼ 收起'}</button>
    <button id="submitExamBtn" onclick="submitExam()" ${submitDisabled?'disabled':''} title="${escapeHTML(submitTitle)}" style="margin-left:auto;padding:4px 14px;background:var(--red);color:white;border:none;border-radius:4px;font-size:12px;font-weight:700;cursor:pointer;flex-shrink:0;">${submitLabel}</button>`;
}

function jumpToSection(title,el){
  $$(".sidebar-tab").forEach(t=>t.classList.remove("active"));
  el.classList.add("active");
  // Jump to first unanswered in this section, or first question
  const inSection=S.states.filter(s=>s.section===title);
  const firstUnanswered=inSection.find(s=>s.state==="unanswered");
  if(firstUnanswered) goToQuestion(S.states.indexOf(firstUnanswered));
  else if(inSection.length>0) goToQuestion(S.states.indexOf(inSection[0]));
}

function setSidebar(expand){
  const grid=$("#answerGrid");
  if(expand){ grid.classList.add("expanded"); }
  else { grid.classList.remove("expanded"); }
  if(S.states.length) renderAnswerGrid();
}
function toggleSidebarCollapse(){
  const sidebar=document.querySelector('.quiz-sidebar');
  sidebar.classList.toggle('collapsed');
  renderStatsBar();
}
// ========== Abandon exam ==========
let abandonState={}; // {id: "idle"|"confirm"}
function toggleAbandon(id,force){
  const inner=document.querySelector(`#card-${id} .exam-card-inner`);
  const btn=document.querySelector(`#card-${id} .card-abandon`);
  const trigger=document.querySelector(`#card-${id} .card-dots`);
  const open=force!==undefined?force:!inner.classList.contains("open");
  trigger?.setAttribute("aria-expanded",String(open));
  if(open){
    inner.classList.add("open");
    abandonState[id]="idle";
    btn.innerHTML="放弃<br>考试";
    btn.setAttribute("aria-label",`放弃考试：${btn.dataset.examName}`);
    btn.removeAttribute("title");
  } else {
    if(document.activeElement===btn) trigger?.focus();
    inner.classList.remove("open");
    delete abandonState[id];
  }
}
async function abandonExam(id){
  if(S.abandonInFlight[id]) return;
  if(abandonState[id]!=="confirm"){
    abandonState[id]="confirm";
    const btn=document.querySelector(`#card-${id} .card-abandon`);
    btn.innerHTML="确认<br>结束";
    btn.setAttribute("aria-label",`确认放弃考试：${btn.dataset.examName}`);
    btn.title="放弃会直接结束并交卷当前考试记录";
    btn.style.animation="none"; btn.offsetHeight; btn.style.animation="pulse .3s ease";
    return;
  }
  const exam=S.exams.find(item=>String(item.id)===String(id));
  if(!exam) return;
  const listToken=S.listLoadToken;
  const requestToken=++S.abandonRequestToken;
  S.abandonInFlight[id]=requestToken;
  const btn=document.querySelector(`#card-${id} .card-abandon`);
  btn.innerHTML="正在<br>结束";
  btn.setAttribute("aria-label",`正在放弃考试：${btn.dataset.examName}`);
  btn.style.pointerEvents="none";
  const r=await api("/api/exams/"+id+"/submit",{method:"POST"});
  if(S.abandonInFlight[id]!==requestToken) return;
  delete S.abandonInFlight[id];
  if(listToken!==S.listLoadToken) return;
  if(!isExamListActive()){
    S.examListLoaded=false;
    return;
  }
  if(r.error){
    btn.innerHTML="重试<br>结束";
    btn.setAttribute("aria-label",`重试放弃考试：${btn.dataset.examName}`);
    btn.style.pointerEvents="auto";
    const card=document.getElementById("card-"+id);
    let error=card.querySelector(".exam-card-error");
    if(!error){ error=document.createElement("div"); error.className="exam-card-error"; card.appendChild(error); }
    error.textContent=r.error;
    return;
  }
  S.suppressedExamStates[String(id)]=exam.wfs;
  S.exams=S.exams.filter(item=>String(item.id)!==String(id));
  delete abandonState[id];
  renderExamList(S.exams);
  await loadExams();
  setTimeout(()=>{
    if(isExamListActive()) loadExams();
  },1000);
}
// Click outside to close any open abandon
document.addEventListener("click",e=>{
  for(const id of Object.keys(abandonState)){
    const card=document.getElementById("card-"+id);
    if(card&&!card.contains(e.target)&&!S.abandonInFlight[id]){
      toggleAbandon(id,false);
    }
  }
});

// Swipe on exam cards → reveal/hide abandon
let cardTouchX=0;
document.addEventListener("touchstart",e=>{
  const card=e.target.closest(".exam-card");
  if(card) cardTouchX=e.touches[0].clientX;
},{passive:true});
document.addEventListener("touchend",e=>{
  const card=e.target.closest(".exam-card");
  if(!card||!S.exams.length) return;
  const dx=e.changedTouches[0].clientX-cardTouchX;
  const id=parseInt(card.id.replace("card-",""));
  if(dx<-50) toggleAbandon(id,true);      // swipe left → open
  else if(dx>50) toggleAbandon(id,false); // swipe right → close
});

// ========== Swipe navigation ==========
let touchX=0,touchY=0;
document.addEventListener("touchstart",e=>{
  touchX=e.touches[0].clientX; touchY=e.touches[0].clientY;
},{passive:true});
document.addEventListener("touchend",e=>{
  if(!$("#quizPage").classList.contains("active")||S.quizCompleted||!S.states.length) return;
  // Ignore swipes on sidebar (answer card)
  if(e.target.closest(".quiz-sidebar, .options, button, a, input, textarea, select")) return;
  for(let el=e.target instanceof Element?e.target:null;el&&el!==$("#quizPage");el=el.parentElement){
    if(el.scrollWidth>el.clientWidth+1) return;
  }
  const dx=e.changedTouches[0].clientX-touchX;
  const dy=e.changedTouches[0].clientY-touchY;
  if(Math.abs(dx)<50||Math.abs(dy)>Math.abs(dx)) return;
  if(dx<0&&S.qIdx<S.states.length-1) goToQuestion(S.qIdx+1);
  else if(dx>0&&S.qIdx>0) goToQuestion(S.qIdx-1);
});

// Keyboard navigation is deliberately limited to unmodified keys on the quiz page.
document.addEventListener("keydown",event=>{
  if(event.ctrlKey||event.altKey||event.metaKey||event.shiftKey||event.isComposing) return;
  if(!$("#quizPage").classList.contains("active")||S.quizCompleted||!S.questions.length) return;

  const target=event.target;
  if(target instanceof HTMLElement&&(target.closest("input, textarea, select, button, a, [role='button']")||target.isContentEditable)) return;

  const key=event.key;
  const q=S.questions[S.qIdx];
  if(!q) return;

  if(key==="ArrowUp"){
    event.preventDefault();
    if(S.qIdx>0) goToQuestion(S.qIdx-1);
    return;
  }
  if(key==="ArrowDown"){
    event.preventDefault();
    if(S.qIdx<S.questions.length-1) goToQuestion(S.qIdx+1);
    return;
  }

  if(S.answered[q._id]) return;

  const optionKey=key.toUpperCase();
  if(["A","B","C","D"].includes(optionKey)){
    event.preventDefault();
    highlightSelectedOption(optionKey);
    return;
  }
  if(key==="Enter"){
    event.preventDefault();
    if(q._isMulti) confirmMultiSelection();
    else{
      const selected=getSelectedOption(q);
      if(selected) submitSelection([selected]);
      else if(S.qIdx<S.questions.length-1) goToQuestion(S.qIdx+1);
    }
    return;
  }
  if(key==="Escape"){
    event.preventDefault();
    clearSelectedOption();
    return;
  }
  if(key!=="ArrowLeft"&&key!=="ArrowRight") return;
  if(q._isMulti) return;

  event.preventDefault();
  const options=getOptionLetters(q);
  if(!options.length) return;
  const selected=getSelectedOption(q);
  const currentIndex=options.indexOf(selected);
  const nextIndex=currentIndex===-1
    ?(key==="ArrowLeft"?options.length-1:0)
    :(key==="ArrowLeft"
      ?(currentIndex-1+options.length)%options.length
      :(currentIndex+1)%options.length);
  highlightSelectedOption(options[nextIndex]);
});

// Auto expand/collapse by orientation
const orientMQ=window.matchMedia("(orientation: landscape)");
orientMQ.addEventListener("change",e=>setSidebar(e.matches));
// Init: landscape→expand, portrait→collapse
if(orientMQ.matches) setSidebar(true);

function showExamList(){
  S.routeToken++;
  activateHomeTab("exams",{historyMode:"push",refresh:true});
  focusHomeHeading("exams");
}

// ========== Submit Exam ==========
function firstUnsyncedAnswer(){
  const issues=Object.keys(S.answerPayloadByQuestion).map(questionId=>({
    questionId,
    status:S.answerSyncState[questionId]?.status||"error",
  })).filter(issue=>issue.status!=="synced");
  return issues.find(issue=>issue.status==="error")||issues[0]||null;
}

function showAnswerSyncBlock(issue){
  const index=S.questions.findIndex(question=>String(question._id)===String(issue.questionId));
  if(index>=0&&index!==S.qIdx) goToQuestion(index);
  const pending=issue.status==="pending";
  setQuizStatus(
    pending?"仍有答案正在同步，请等待同步完成后再交卷":"有答案同步失败，请先重新同步后再交卷",
    pending?"":"error",
  );
}

function firstPendingMark(){
  return Object.keys(S.markSyncState).find(questionId=>S.markSyncState[questionId]?.status==="pending")||null;
}

function showMarkSyncBlock(questionId){
  const index=S.questions.findIndex(question=>String(question._id)===String(questionId));
  if(index>=0&&index!==S.qIdx) goToQuestion(index);
  setQuizStatus("仍有题目标记正在同步，请等待完成后再交卷");
}

async function submitExam(skipConfirmation=false,expectedExamId=null,expectedLoadToken=null){
  if(S.submitInFlight||S.quizCompleted||!S.currentExam) return;
  const id=String(S.currentExam.examInfoId);
  const loadToken=S.examLoadToken;
  if(expectedExamId!==null&&(String(expectedExamId)!==id||expectedLoadToken!==loadToken)) return;
  const pendingMark=firstPendingMark();
  if(pendingMark){
    showMarkSyncBlock(pendingMark);
    return;
  }
  const syncIssue=firstUnsyncedAnswer();
  if(syncIssue){
    showAnswerSyncBlock(syncIssue);
    return;
  }
  if(!skipConfirmation&&!confirm("交卷会结束当前考试并写入真实记录，确定继续吗？")) return;
  S.submitInFlight=true;
  cancelAutoAdvance();
  renderStatsBar();
  setQuizStatus("正在提交并获取成绩…");
  const r=await api(`/api/exams/${id}/submit`,{method:"POST"});
  if(!canUpdateQuiz(id,loadToken)) return;
  S.submitInFlight=false;
  if(r.error){
    renderStatsBar();
    setQuizStatus(r.error,"error",{label:"重新提交",run:()=>submitExam(true,id,loadToken)});
    return;
  }
  S.quizCompleted=true;
  stopQuestionTimer();
  renderStatsBar();
  setQuizStatus("");
  const sc=$("#quizScroll");
  sc.innerHTML=`
    <div class="q-block" id="qBlock" style="display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:70vh;text-align:center;gap:24px;padding:20px;">
      <!-- Celebration Owl Mascot -->
      <svg viewBox="0 0 100 100" width="140" height="140" style="animation: bounce 0.6s ease infinite alternate;">
        <!-- Body -->
        <rect x="20" y="20" width="60" height="70" rx="30" fill="var(--mascot-body)" />
        <!-- Belly -->
        <path d="M 30 62 Q 50 50 70 62 Q 50 85 30 62" fill="var(--mascot-belly)" />
        <!-- Crown -->
        <polygon points="50,15 40,25 45,23 50,18 55,23 60,25" fill="var(--yellow)" />
        <!-- Eyes -->
        <path d="M 28 45 Q 36 38 44 45" stroke="white" stroke-width="4" fill="none" stroke-linecap="round" />
        <path d="M 56 45 Q 64 38 72 45" stroke="white" stroke-width="4" fill="none" stroke-linecap="round" />
        <!-- Beak -->
        <polygon points="50,47 45,54 55,54" fill="var(--mascot-feet)" />
        <!-- Cheeks -->
        <circle cx="26" cy="52" r="3" fill="var(--mascot-cheeks)" opacity="0.3" />
        <circle cx="74" cy="52" r="3" fill="var(--mascot-cheeks)" opacity="0.3" />
      </svg>
      <style>
        @keyframes bounce {
          from { transform: translateY(0); }
          to { transform: translateY(-8px); }
        }
      </style>

      <div style="font-family:var(--font-display);font-size:36px;font-weight:800;color:var(--accent);">单元挑战完成！</div>

      <div style="background:var(--surface);border:2px solid var(--border);border-bottom:4px solid var(--border);border-radius:var(--radius-lg);padding:24px;width:100%;max-width:360px;">
        <div style="font-family:var(--font-display);font-size:54px;font-weight:800;color:var(--orange);margin-bottom:8px;" class="num">${escapeHTML(r.score)}<span style="font-size:20px;color:var(--text2)"> 分</span></div>
        <div style="font-size:15px;color:var(--text2);font-weight:800;line-height:1.8;">
          击败全国 <b style="color:var(--accent);font-size:17px;">${escapeHTML(r.beatRate)}%</b> 的考生<br>
          当前排名 <b style="color:var(--blue);font-size:17px;">#${escapeHTML(r.rank)}</b>
        </div>
      </div>

      <button onclick="showExamList()" class="cta-btn" style="padding:14px 48px;font-size:16px;">返回路线图</button>
    </div>`;
}

// ========== Init ==========
syncAutoAdvanceControls();
syncThemeControls();
if("serviceWorker"in navigator){
  navigator.serviceWorker.register("/sw.js")
    .then(r=>console.log("SW registered:",r.scope))
    .catch(e=>console.warn("SW failed:",e.message));
}
(async function(){
  route();
})();
