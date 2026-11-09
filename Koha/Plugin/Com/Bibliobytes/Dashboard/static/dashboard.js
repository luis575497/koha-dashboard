(() => {
  const root = document.getElementById('bb-dashboard');
  if (!root) return;
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const activateTab = (selected, focus = false) => {
    tabs.forEach(tab => {
      const active = tab === selected;
      tab.setAttribute('aria-selected', String(active));
      tab.tabIndex = active ? 0 : -1;
      const panel = document.getElementById(tab.getAttribute('aria-controls'));
      if (panel) panel.hidden = !active;
    });
    if (focus) selected.focus();
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => activateTab(tab));
    tab.addEventListener('keydown', e => {
      let next = index;
      if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = (index + 1) % tabs.length;
      else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = (index + tabs.length - 1) % tabs.length;
      else if (e.key === 'Home') next = 0;
      else if (e.key === 'End') next = tabs.length - 1;
      else return;
      e.preventDefault();
      activateTab(tabs[next], true);
    });
  });
  const form = document.getElementById('bb-filters');
  const status = document.getElementById('bb-status');
  const endpoint = window.location.pathname;
  const baseQuery = new URLSearchParams(window.location.search);
  const fmt = n => new Intl.NumberFormat('es').format(Number(n || 0));
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

  const params = () => {
    const p = new URLSearchParams(baseQuery);
    p.set('sub', 'data');
    p.set('range', document.getElementById('bb-range').value);
    ['from', 'to', 'branch'].forEach(k => {
      const v = form.elements[k].value;
      if (v) p.set(k, v); else p.delete(k);
    });
    p.set('idle_years',document.getElementById('bb-inactive-years')?.value||'3');
    return p;
  };

  const chart = (rows, key, bar = false) => {
    if (!rows?.length) return '<p>Sin datos para este período.</p>';
    const W=700,H=245,L=42,R=12,T=14,B=40,pw=W-L-R,ph=H-T-B;
    const max=Math.max(1,...rows.map(d=>Number(d[key]||0)));
    let s=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Gráfico mensual"><line class="axis" x1="${L}" y1="${T+ph}" x2="${W-R}" y2="${T+ph}"/>`;
    [0,.5,1].forEach(f=>{const y=T+ph*(1-f);s+=`<line class="axis" x1="${L}" y1="${y}" x2="${W-R}" y2="${y}"/><text x="3" y="${y+4}">${fmt(max*f)}</text>`;});
    const step=pw/rows.length;
    if(bar){
      const bw=step*.56;
      rows.forEach((d,i)=>{const v=Number(d[key]||0),h=ph*v/max,x=L+i*step+(step-bw)/2,y=T+ph-h;s+=`<rect class="bar" x="${x}" y="${y}" width="${bw}" height="${h}" rx="3"><title>${esc(d.month)}: ${fmt(v)}</title></rect><text text-anchor="middle" x="${L+i*step+step/2}" y="${H-12}">${esc(d.month)}</text>`;});
    } else {
      let segment=[];
      rows.forEach((d,i)=>{if(d.observed===false){if(segment.length>1)s+=`<polyline class="line-issues" points="${segment.join(' ')}"/>`;segment=[];}else segment.push(`${L+(rows.length===1?pw/2:i*pw/(rows.length-1))},${T+ph-ph*Number(d[key]||0)/max}`);});
      if(segment.length>1)s+=`<polyline class="line-issues" points="${segment.join(' ')}"/>`;
      rows.forEach((d,i)=>{const x=L+(rows.length===1?pw/2:i*pw/(rows.length-1)),observed=d.observed!==false,y=T+ph-ph*Number(d[key]||0)/max;if(observed)s+=`<circle cx="${x}" cy="${y}" r="4" fill="currentColor"><title>${esc(d.month)}: ${fmt(d[key])} préstamos</title></circle>`;else s+=`<circle cx="${x}" cy="${T+ph}" r="4" fill="white" stroke="#8593a1" stroke-dasharray="2 2"><title>${esc(d.month)}: sin datos registrados</title></circle>`;if(rows.length<=15||i%6===0||i===rows.length-1)s+=`<text text-anchor="middle" x="${x}" y="${H-12}">${esc(d.month)}</text>`;});
    }
    return s+'</svg>';
  };

  const monthSeries = (rows, endDate) => {
    const values=new Map((rows||[]).map(r=>[r.month,Number(r.issues||0)]));
    if(!values.size)return [];
    const [yy,mm]=endDate.slice(0,7).split('-').map(Number),out=[];
    for(let n=35;n>=0;n--){const d=new Date(Date.UTC(yy,mm-1-n,1)),key=`${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}`,row=(rows||[]).find(r=>r.month===key);out.push({month:key,issues:values.get(key)||0,observed:!!row&&Number(row.events||0)>0});}
    return out;
  };
  const monthFlow = (rows, from, to) => {
    const map=new Map((rows||[]).map(r=>[r.month,r])),start=new Date(`${from.slice(0,7)}-01T00:00:00Z`),end=new Date(`${to.slice(0,7)}-01T00:00:00Z`),out=[];
    for(let d=new Date(start);d<=end;d.setUTCMonth(d.getUTCMonth()+1)){const month=`${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}`,row=map.get(month);out.push(row?{...row,observed:Number(row.events||0)>0}:{month,issues:0,renewals:0,returns:0,events:0,observed:false});}
    return out;
  };
  const forecast = series => {
    if(series.length<36||series.some(x=>!x.observed))return [];
    const lookup=new Map(series.map(x=>[x.month,x.issues]));
    const errors=[];
    series.slice(-24).forEach(row=>{const d=new Date(`${row.month}-01T00:00:00Z`);d.setUTCMonth(d.getUTCMonth()-12);const prior=`${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}`;if(lookup.has(prior))errors.push(Math.abs(row.issues-lookup.get(prior)));});
    const mae=errors.length?errors.reduce((a,b)=>a+b,0)/errors.length:null;
    const last=series.at(-1),[yy,mm]=last.month.split('-').map(Number),result=[];
    for(let n=1;n<=3;n++){const d=new Date(Date.UTC(yy,mm-1+n,1)),month=`${d.getUTCFullYear()}-${String(d.getUTCMonth()+1).padStart(2,'0')}`,bases=[12,24].map(years=>{const prior=new Date(Date.UTC(d.getUTCFullYear(),d.getUTCMonth(),1));prior.setUTCMonth(prior.getUTCMonth()-years);return `${prior.getUTCFullYear()}-${String(prior.getUTCMonth()+1).padStart(2,'0')}`;});if(bases.some(base=>!lookup.has(base)))return [];const value=(lookup.get(bases[0])+lookup.get(bases[1]))/2,spread=mae===null?0:1.28*mae,low=Math.max(0,Math.round(value-spread)),high=Math.round(value+spread);if(low===0||high-low>value)return [];result.push({month,estimate:Math.round(value),low,high});}
    return result;
  };
  const forecastTable = rows => {
    if(!rows.length)return '<p>La referencia se oculta porque no hay 36 meses consecutivos con eventos o la variación histórica produciría un rango demasiado amplio.</p>';
    return `<table><thead><tr><th>Mes</th><th>Estimación</th><th>Rango orientativo</th></tr></thead><tbody>${rows.map(r=>`<tr><td>${esc(r.month)}</td><td>${fmt(r.estimate)}</td><td>${fmt(r.low)}–${fmt(r.high)}</td></tr>`).join('')}</tbody></table>`;
  };
  const flowChart = rows => {
    if(!rows?.length)return '<p>Sin datos para este período.</p>';
    const W=700,H=245,L=46,R=12,T=14,B=40,pw=W-L-R,ph=H-T-B,keys=['issues','renewals','returns'],max=Math.max(1,...rows.flatMap(r=>keys.map(k=>Number(r[k]||0))));
    let s=`<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="Préstamos, renovaciones y devoluciones por mes"><line class="axis" x1="${L}" y1="${T+ph}" x2="${W-R}" y2="${T+ph}"/>`;
    [0,.5,1].forEach(f=>{const y=T+ph*(1-f);s+=`<line class="axis" x1="${L}" y1="${y}" x2="${W-R}" y2="${y}"/><text x="3" y="${y+4}">${fmt(max*f)}</text>`;});
    keys.forEach(key=>{let segment=[];rows.forEach((row,i)=>{if(row.observed===false){if(segment.length>1)s+=`<polyline class="line-${key}" points="${segment.join(' ')}"/>`;segment=[];}else segment.push(`${L+(rows.length===1?pw/2:i*pw/(rows.length-1))},${T+ph-ph*Number(row[key]||0)/max}`);});if(segment.length>1)s+=`<polyline class="line-${key}" points="${segment.join(' ')}"/>`;});
    rows.forEach((row,i)=>{const x=L+(rows.length===1?pw/2:i*pw/(rows.length-1));if(row.observed===false)s+=`<circle cx="${x}" cy="${T+ph}" r="4" fill="white" stroke="#8593a1" stroke-dasharray="2 2"><title>${esc(row.month)}: sin datos registrados</title></circle>`;if(rows.length<=15||i%6===0||i===rows.length-1)s+=`<text text-anchor="middle" x="${x}" y="${H-12}">${esc(row.month)}</text>`;});
    return s+'</svg>';
  };
  const makeInsights = (d, series, predicted) => {
    const k=d.kpis,items=[];
    if(k.checkouts_change!==null&&k.checkouts_change!==undefined){const n=Number(k.checkouts_change);items.push({title:n<=-20?'Alerta de circulación':'Circulación',text:`Los préstamos ${n>0?'subieron':n<0?'bajaron':'se mantuvieron'} ${Math.abs(n).toFixed(1)}% frente al período anterior de igual duración.`});}
    if(k.same_period_change!==null&&k.same_period_change!==undefined)items.push({title:'Comparación interanual del mismo rango',text:`${Number(k.same_period_change)>=0?'Subieron':'Bajaron'} ${Math.abs(Number(k.same_period_change)).toFixed(1)}% frente a las mismas fechas del año anterior (${d.same_year_from}–${d.same_year_to}).`});
    items.push({title:'Alcance de la colección',text:`Se prestó al menos un ejemplar de ${Number(k.title_movement||0).toFixed(1)}% de los títulos disponibles en la colección filtrada durante el período. Es cobertura de títulos, no rotación por ejemplar.`});
    if(k.returning_rate!==null&&k.returning_rate!==undefined)items.push({title:'Continuidad de uso',text:`${Number(k.returning_rate).toFixed(1)}% de las personas activas en el período anterior también tuvieron actividad ahora (${fmt(k.returning_active)} de ${fmt(k.previous_active)}).`});
    if(k.new_borrower_activation!==null&&k.new_borrower_activation!==undefined)items.push({title:'Incorporación de socios',text:`${Number(k.new_borrower_activation).toFixed(1)}% de los socios inscritos en este período ya tienen al menos un préstamo registrado.`});
    const days=['domingo','lunes','martes','miércoles','jueves','viernes','sábado'],hourMap=new Map((d.day_hour||[]).map(r=>[`${r.weekday}-${r.hour}`,Number(r.checkouts||0)]));let peakWindow={total:0,day:0,start:0};
    for(let day=0;day<7;day++)for(let start=0;start<=18;start++){let total=0;for(let h=start;h<start+6;h++)total+=hourMap.get(`${day}-${h}`)||0;if(total>peakWindow.total)peakWindow={total,day,start};}
    if(peakWindow.total>0)items.push({title:'Hora de mayor actividad',text:`La franja de seis horas con más préstamos es ${days[peakWindow.day]} de ${String(peakWindow.start).padStart(2,'0')}:00 a ${String(peakWindow.start+6).padStart(2,'0')}:00 (${fmt(peakWindow.total)} préstamos).`});
    return items.map(x=>`<article class="bb-insight"><strong>${esc(x.title)}</strong><p>${esc(x.text)}</p></article>`).join('');
  };

  const table = (el, rows, fields, labels) => {
    if (!rows?.length) { el.innerHTML='<p>Sin datos para este período.</p>'; return; }
    const searchId=`table-search-${el.id}`;
    el.innerHTML=`<label class="bb-table-search">Buscar <input type="search" id="${searchId}" aria-label="Buscar en tabla"></label><table><thead><tr>${labels.map((x,i)=>`<th><button type="button" class="bb-sort" data-column="${i}">${esc(x)} ↕</button></th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${fields.map(f=>`<td>${esc(r[f])}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
    const body=el.querySelector('tbody');
    el.querySelector(`#${searchId}`).addEventListener('input',ev=>{const q=ev.target.value.toLocaleLowerCase();[...body.rows].forEach(row=>row.hidden=!row.textContent.toLocaleLowerCase().includes(q));});
    el.querySelectorAll('.bb-sort').forEach(button=>button.addEventListener('click',()=>{const i=Number(button.dataset.column),rows=[...body.rows],ascending=button.dataset.asc!=='true';rows.sort((a,b)=>{const x=a.cells[i].textContent.trim(),y=b.cells[i].textContent.trim(),nx=Number(x.replace(/[^0-9.-]/g,'')),ny=Number(y.replace(/[^0-9.-]/g,''));return (Number.isNaN(nx)||Number.isNaN(ny)?x.localeCompare(y,'es'):nx-ny)*(ascending?1:-1);});rows.forEach(row=>body.appendChild(row));button.dataset.asc=String(ascending);}));
  };

  const heatmap = rows => {
    if (!rows?.length) return '<p>Sin datos para este período.</p>';
    const days=['Dom','Lun','Mar','Mié','Jue','Vie','Sáb'], hours=Array.from({length:24},(_,i)=>i);
    const values=new Map(rows.map(r=>[`${r.weekday}-${r.hour}`,Number(r.checkouts||0)]));
    const max=Math.max(1,...values.values()), W=760, left=44, top=30, cw=27, ch=25;
    let s=`<svg viewBox="0 0 ${W} ${top+days.length*ch+8}" role="img" aria-label="Préstamos por día y hora">`;
    hours.forEach(h=>{if(h%2===0)s+=`<text x="${left+h*cw+cw/2}" y="18" text-anchor="middle">${h}</text>`;});
    days.forEach((day,d)=>{s+=`<text x="${left-7}" y="${top+d*ch+17}" text-anchor="end">${day}</text>`;hours.forEach(h=>{const v=values.get(`${d}-${h}`)||0,op=.12+.88*v/max;s+=`<rect class="heat-cell" x="${left+h*cw}" y="${top+d*ch}" width="${cw-2}" height="${ch-2}" rx="3" opacity="${op}"><title>${day}, ${h}:00 — ${fmt(v)} préstamos</title></rect>`;});});
    return s+'</svg>';
  };

  const load = async e => {
    if(e)e.preventDefault();
    status.textContent='Cargando estadísticas…';
    try {
      const res=await fetch(`${endpoint}?${params()}`,{credentials:'same-origin',headers:{Accept:'application/json'}});
      if(!res.ok)throw Error(`HTTP ${res.status}`);
      const d=await res.json(),k=d.kpis;
      const cards={checkouts:k.checkouts,'biblio-checkouts':k.bibliographic_checkouts,overdue:k.overdue,active:k.active_borrowers,'local-use':k.local_use,idle:k.idle_items,items:k.items,titles:k.titles,borrowers:k.borrowers,'fines-generated':k.fines_generated,'fines-paid':k.fines_paid,'fines-outstanding':k.fines_outstanding};
      Object.entries(cards).forEach(([n,v])=>{const el=document.getElementById(`k-${n}`);if(el)el.textContent=fmt(v);});
      document.getElementById('k-title-movement').textContent=`${Number(k.title_movement||0).toFixed(1)}%`;
      document.getElementById('k-title-movement-detail').textContent=`${fmt(k.circulated_titles)} de ${fmt(k.titles)} títulos distintos prestados`;
      document.getElementById('k-active-share').textContent=`${Number(k.active_share||0).toFixed(1)}%`;
      document.getElementById('k-eligible-share').textContent=`${Number(k.eligible_active_share||0).toFixed(1)}%`;
      document.getElementById('k-eligible-detail').textContent=`${fmt(k.active_eligible)} activos de ${fmt(k.eligible_borrowers)} elegibles; categorías ajustables en Configurar`;
      document.getElementById('k-returning-rate').textContent=k.returning_rate===null||k.returning_rate===undefined?'—':`${Number(k.returning_rate).toFixed(1)}%`;
      document.getElementById('k-returning-detail').textContent=`${fmt(k.returning_active)} de ${fmt(k.previous_active)} socios activos en el período anterior`;
      document.getElementById('k-new-activation').textContent=k.new_borrower_activation===null||k.new_borrower_activation===undefined?'—':`${Number(k.new_borrower_activation).toFixed(1)}%`;
      document.getElementById('k-new-activation-detail').textContent=`${fmt(k.new_borrowers_active)} de ${fmt(k.new_borrowers)} nuevos socios con préstamo`;
      const leader=d.top_borrowers?.[0];
      document.getElementById('k-top-borrower').textContent=leader?.borrower||'Sin datos';
      document.getElementById('k-top-borrower-detail').textContent=leader?`${fmt(leader.checkouts)} préstamos en el período`:'No hay préstamos asociados a usuarios';
      const change=k.checkouts_change;
      document.getElementById('k-checkouts-change').textContent=change===null||change===undefined?`Sin base de comparación (${fmt(k.previous_checkouts)} préstamos en ${d.previous_from}–${d.previous_to})`:`${change>=0?'▲':'▼'} ${Math.abs(change).toFixed(1)}% vs período anterior`;
      const goalCard=document.getElementById('bb-goal-card');goalCard.hidden=!Number(k.checkout_goal);if(Number(k.checkout_goal)){document.getElementById('k-goal-progress').textContent=`${Math.min(100,Number(k.checkout_goal_progress||0)).toFixed(1)}%`;document.getElementById('k-goal-detail').textContent=`${fmt(k.checkouts)} de ${fmt(k.checkout_goal)} préstamos meta`;}
      document.getElementById('k-holds').textContent=fmt(d.holds?.waiting);document.getElementById('k-hold-wait').textContent=Number(d.holds?.avg_wait||0).toFixed(1);
      const noFines=!Number(k.fines_generated)&&!Number(k.fines_paid)&&!Number(k.fines_outstanding);document.getElementById('bb-fines-kpis').hidden=noFines;document.querySelectorAll('.bb-fines-panel').forEach(el=>el.hidden=noFines);document.getElementById('fines-no-data').hidden=!noFines;
      const inactiveYears=document.getElementById('bb-inactive-years').value;document.getElementById('inactive-title').textContent=`Ejemplares sin préstamos en los últimos ${inactiveYears} ${inactiveYears==='1'?'año':'años'}`;
      const flowRows=monthFlow(d.flow,d.from,d.to);
      document.getElementById('chart-flow').innerHTML=flowChart(flowRows);
      const series=monthSeries(d.history,d.to),predicted=forecast(series);
      document.getElementById('chart-history').innerHTML=chart(series,'issues');
      document.getElementById('chart-forecast').innerHTML=forecastTable(predicted);
      const insightHTML=makeInsights(d,series,predicted);document.getElementById('bb-insights').innerHTML=insightHTML;document.getElementById('bb-summary-insights').innerHTML=insightHTML.split('</article>').slice(0,3).join('</article>');
      document.getElementById('chart-summary').innerHTML=flowChart(flowRows);
      document.getElementById('chart-fines').innerHTML=chart(d.fines,'generated',true);
      document.getElementById('chart-cataloguing').innerHTML=chart(d.cataloguing,'records',true);
      document.getElementById('chart-new-borrowers').innerHTML=chart(d.new_borrowers,'new_borrowers',true);
      document.getElementById('chart-day-hour').innerHTML=heatmap(d.day_hour);
      const bands=d.overdue_bands?.[0]||{};
      table(document.getElementById('table-overdue-bands'),[
        {periodo:'1–7 días',ejemplares:fmt(bands.days_1_7)},{periodo:'8–30 días',ejemplares:fmt(bands.days_8_30)},
        {periodo:'31–90 días',ejemplares:fmt(bands.days_31_90)},{periodo:'Más de 90 días',ejemplares:fmt(bands.days_over_90)}
      ],['periodo','ejemplares'],['Antigüedad','Vencidos']);
      table(document.getElementById('table-itemtype-use'),d.itemtype_use,['item_type','copies','checkouts','turnover'],['Tipo de ítem','Ejemplares','Préstamos','Rotación']);
      table(document.getElementById('table-itemtype-equipment'),d.itemtype_use_equipment,['item_type','copies','checkouts','turnover'],['Tipo de equipo','Ejemplares','Préstamos','Rotación']);
      table(document.getElementById('table-borrowers-category'),d.borrowers_by_category,['category','active_borrowers'],['Categoría','Socios activos']);
      table(document.getElementById('table-titles'),d.top_titles,['title','checkouts'],['Título','Préstamos']);
      table(document.getElementById('table-equipment'),d.top_equipment,['title','item_type','checkouts'],['Equipo','Tipo','Préstamos']);
      table(document.getElementById('table-zero-searches'),d.zero_searches,['search_term','searches'],['Término repetido sin resultados','Búsquedas']);
      table(document.getElementById('table-inactive-class'),d.inactive_by_class,['classification','idle_copies'],['Clasificación / Dewey aproximado','Ejemplares']);
      table(document.getElementById('table-loans-by-class'),d.loans_by_class,['classification','checkouts'],['Clasificación / Dewey aproximado','Préstamos']);
      const branchPanel=document.getElementById('branch-comparison-panel');branchPanel.hidden=!(d.branch_comparison||[]).length;table(document.getElementById('table-branch-comparison'),d.branch_comparison,['branchname','checkouts'],['Biblioteca','Préstamos']);
      table(document.getElementById('table-cataloguers'),d.cataloguers,['cataloguer','records'],['Catalogador','Registros']);
      table(document.getElementById('table-top-borrowers'),(d.top_borrowers||[]).map((r,i)=>({position:i+1,...r})),['position','borrower','checkouts'],['N.º','Usuario','Préstamos']);
      document.querySelectorAll('.bb-csv').forEach(a=>{const p=params();p.set('sub','csv');p.set('dataset',a.dataset.dataset);a.href=`${endpoint}?${p}`;});
      status.textContent=`Datos del ${d.from} al ${d.to}. Comparación: ${d.previous_from} al ${d.previous_to}.`;
    } catch(err){status.textContent='No se pudieron cargar las estadísticas. Revise los permisos y los registros de Koha.';console.error(err);}
  };
  document.getElementById('bb-range').addEventListener('change',()=>{const custom=document.getElementById('bb-range').value==='custom';form.elements.from.disabled=!custom;form.elements.to.disabled=!custom;});
  document.getElementById('bb-inactive-years').addEventListener('change',load);
  document.getElementById('bb-print').addEventListener('click',()=>window.print());
  form.addEventListener('submit',load);
  const qs=new URLSearchParams(location.search);if(qs.get('branch'))document.getElementById('bb-branch').value=qs.get('branch');
  load();
})();
