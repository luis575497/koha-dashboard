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
      const pts=rows.map((d,i)=>`${L+(rows.length===1?pw/2:i*pw/(rows.length-1))},${T+ph-ph*Number(d[key]||0)/max}`).join(' ');
      s+=`<polyline class="line-issues" points="${pts}"/>`;
      rows.forEach((d,i)=>{const x=L+(rows.length===1?pw/2:i*pw/(rows.length-1)),y=T+ph-ph*Number(d[key]||0)/max;s+=`<circle cx="${x}" cy="${y}" r="4" fill="currentColor"><title>${esc(d.month)}: ${fmt(d[key])}</title></circle><text text-anchor="middle" x="${x}" y="${H-12}">${esc(d.month)}</text>`;});
    }
    return s+'</svg>';
  };

  const table = (el, rows, fields, labels) => {
    if (!rows?.length) { el.innerHTML='<p>Sin datos para este período.</p>'; return; }
    el.innerHTML=`<table><thead><tr>${labels.map(x=>`<th>${esc(x)}</th>`).join('')}</tr></thead><tbody>${rows.map(r=>`<tr>${fields.map(f=>`<td>${esc(r[f])}</td>`).join('')}</tr>`).join('')}</tbody></table>`;
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
      const cards={checkouts:k.checkouts,overdue:k.overdue,active:k.active_borrowers,idle:k.idle_items,items:k.items,titles:k.titles,borrowers:k.borrowers,'fines-generated':k.fines_generated,'fines-paid':k.fines_paid,'fines-outstanding':k.fines_outstanding};
      Object.entries(cards).forEach(([n,v])=>{const el=document.getElementById(`k-${n}`);if(el)el.textContent=fmt(v);});
      document.getElementById('k-title-movement').textContent=`${Number(k.title_movement||0).toFixed(1)}%`;
      document.getElementById('k-title-movement-detail').textContent=`${fmt(k.circulated_titles)} de ${fmt(k.titles)} títulos distintos prestados`;
      const leader=d.top_borrowers?.[0];
      document.getElementById('k-top-borrower').textContent=leader?.borrower||'Sin datos';
      document.getElementById('k-top-borrower-detail').textContent=leader?`${fmt(leader.checkouts)} préstamos en el período`:'No hay préstamos asociados a usuarios';
      const change=k.checkouts_change;
      document.getElementById('k-checkouts-change').textContent=change===null||change===undefined?`Sin base de comparación (${fmt(k.previous_checkouts)} préstamos en ${d.previous_from}–${d.previous_to})`:`${change>=0?'▲':'▼'} ${Math.abs(change).toFixed(1)}% vs período anterior`;
      document.getElementById('chart-flow').innerHTML=chart(d.flow,'issues');
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
      table(document.getElementById('table-borrowers-category'),d.borrowers_by_category,['category','active_borrowers'],['Categoría','Socios activos']);
      table(document.getElementById('table-titles'),d.top_titles,['title','checkouts'],['Título','Préstamos']);
      table(document.getElementById('table-cataloguers'),d.cataloguers,['cataloguer','records'],['Catalogador','Registros']);
      table(document.getElementById('table-top-borrowers'),(d.top_borrowers||[]).map((r,i)=>({position:i+1,...r})),['position','borrower','checkouts'],['N.º','Usuario','Préstamos']);
      document.querySelectorAll('.bb-csv').forEach(a=>{const p=params();p.set('sub','csv');p.set('dataset',a.dataset.dataset);a.href=`${endpoint}?${p}`;});
      status.textContent=`Datos del ${d.from} al ${d.to}. Comparación: ${d.previous_from} al ${d.previous_to}.`;
    } catch(err){status.textContent='No se pudieron cargar las estadísticas. Revise los permisos y los registros de Koha.';console.error(err);}
  };
  document.getElementById('bb-range').addEventListener('change',()=>{const custom=document.getElementById('bb-range').value==='custom';form.elements.from.disabled=!custom;form.elements.to.disabled=!custom;});
  form.addEventListener('submit',load);
  const qs=new URLSearchParams(location.search);if(qs.get('branch'))document.getElementById('bb-branch').value=qs.get('branch');
  load();
})();
