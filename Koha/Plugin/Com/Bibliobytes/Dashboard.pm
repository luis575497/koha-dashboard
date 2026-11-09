package Koha::Plugin::Com::Bibliobytes::Dashboard;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use Koha::DateUtils qw(dt_from_string);
use JSON qw(encode_json);
use C4::Context;
use C4::Auth qw(haspermission);
use CGI qw(-utf8);

our $VERSION = '1.6.0';

our $metadata = {
    name            => 'Dashboard bibliotecario',
    author          => 'Bibliobytes',
    description     => 'Dashboard bibliotecario con filtros de material, análisis de colección, tendencias e informes de circulación.',
    date_authored   => '2026-11-06',
    date_updated    => '2026-11-09',
    minimum_version => '24.05.00.000',
    maximum_version => undef,
    version         => $VERSION,
};

sub new {
    my ( $class, $args ) = @_;
    $args ||= {};
    $args->{metadata} = $metadata;
    return $class->SUPER::new($args);
}

sub tool {
    my ($self) = @_;
    my $cgi = $self->{cgi} || CGI->new;
    my $sub = $cgi->param('sub') || '';
    return $self->_data($cgi) if $sub eq 'data';
    return $self->_csv($cgi) if $sub eq 'csv';
    my $template = $self->get_template( { file => 'templates/dashboard.tt' } );
    my $branches = C4::Context->dbh->selectall_arrayref(
        'SELECT branchcode, branchname FROM branches ORDER BY branchname', { Slice => {} }
    );
    my ( $from, $to ) = _range($cgi);
    my $range = $cgi->param('range') || 6;
    $template->param( branches => $branches, plugin_url => $self->get_plugin_http_path,
        initial_from => $from, initial_to => $to, initial_range => $range,
        can_view_names => _can_view_names() );
    $self->output_html( $template->output );
}

sub configure {
    my ($self) = @_;
    my $cgi = $self->{cgi} || CGI->new;
    my $dbh = C4::Context->dbh;
    if ( $cgi->param('save') ) {
        my @types = grep { defined && /\A[[:alnum:]_.-]+\z/ } $cgi->multi_param('non_biblio_itemtypes');
        my @categories = grep { defined && /\A[[:alnum:]_.-]+\z/ } $cgi->multi_param('eligible_categories');
        my $goal = $cgi->param('checkout_goal') || 0;
        $goal = 0 unless $goal =~ /\A\d{1,8}\z/;
        $self->store_data({ non_biblio_itemtypes => join(',', @types), eligible_categories => join(',', @categories), checkout_goal => $goal });
        $self->go_home;
        return;
    }
    my %selected = map { $_ => 1 } split /\s*,\s*/, ( $self->retrieve_data('non_biblio_itemtypes') || '' );
    my %eligible = map { $_ => 1 } split /\s*,\s*/, ( $self->retrieve_data('eligible_categories') || '' );
    my $types = $dbh->selectall_arrayref('SELECT itemtype, description FROM itemtypes ORDER BY description', { Slice => {} });
    my $categories = $dbh->selectall_arrayref('SELECT categorycode,description FROM categories ORDER BY description', { Slice => {} });
    $_->{selected} = $selected{ $_->{itemtype} } ? 1 : 0 for @$types;
    $_->{selected} = $eligible{ $_->{categorycode} } ? 1 : 0 for @$categories;
    my $template = $self->get_template({ file => 'templates/configure.tt' });
    $template->param( itemtypes => $types, categories => $categories, checkout_goal => $self->retrieve_data('checkout_goal') || 0 );
    $self->output_html($template->output);
}

sub _excluded_itemtypes {
    my ($self) = @_;
    return grep { /\A[[:alnum:]_.-]+\z/ } split /\s*,\s*/, ( $self->retrieve_data('non_biblio_itemtypes') || '' );
}

sub _can_view_names {
    my $userenv = C4::Context->userenv || {};
    return 0 unless $userenv->{id};
    return haspermission( $userenv->{id}, { borrowers => 'edit_borrowers' } ) ? 1 : 0;
}

sub _range {
    my ($cgi) = @_;
    my $today = dt_from_string()->ymd;
    my $to = $cgi->param('to') || $today;
    my $months = $cgi->param('range') || 6;
    $months = 6 if $months ne 'custom' && $months !~ /\A(?:1|3|6|12)\z/;
    my $from = $cgi->param('from');
    if ( $months ne 'custom' ) {
        my $dt = dt_from_string($to);
        $dt->subtract( months => $months )->add( days => 1 );
        $from = $dt->ymd;
    }
    $from = $today unless $from =~ /\A\d{4}-\d{2}-\d{2}\z/;
    $to = $today unless $to =~ /\A\d{4}-\d{2}-\d{2}\z/;
    $to = $today if $to gt $today;
    $from = $to if $from gt $to;
    return ($from, $to, $cgi->param('branch') || '');
}

sub _data {
    my ( $self, $cgi ) = @_;
    my ( $from, $to, $branch ) = _range($cgi);
    my $dbh = C4::Context->dbh;
    my @bind = $branch ? ($branch) : ();
    my @excluded_types = $self->_excluded_itemtypes;
    my @eligible_categories = grep { /\A[[:alnum:]_.-]+\z/ } split /\s*,\s*/, ( $self->retrieve_data('eligible_categories') || '' );
    my $idle_years = $cgi->param('idle_years') || 3;
    $idle_years = 3 unless $idle_years =~ /\A(?:1|3|5)\z/;
    my $checkout_goal = $self->retrieve_data('checkout_goal') || 0;
    my $exclude_material = @excluded_types ? 'COALESCE(i.itype,bi.itemtype,\'\') NOT IN (' . join(',', ('?') x @excluded_types) . ')' : '1=1';
    my $equipment_material = @excluded_types ? 'COALESCE(i.itype,bi.itemtype,\'\') IN (' . join(',', ('?') x @excluded_types) . ')' : '1=0';
    my $q = sub { my ($sql,@args)=@_; return $dbh->selectall_arrayref($sql,{Slice=>{}},@args) };
    my $scalar = sub { my ($sql,@args)=@_; my ($v)=$dbh->selectrow_array($sql,undef,@args); return 0 + ($v || 0) };
    my $from_dt = dt_from_string($from);
    my $to_dt   = dt_from_string($to);
    my $period_days = int( ( $to_dt->epoch - $from_dt->epoch ) / 86400 ) + 1;
    my $previous_to = $from_dt->clone->subtract( days => 1 )->ymd;
    my $previous_from = dt_from_string($previous_to)->subtract( days => $period_days - 1 )->ymd;
    my $checkouts = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$from,$to,@bind);
    my $bibliographic_checkouts = $scalar->(q{SELECT COUNT(*) FROM statistics s LEFT JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').' AND i.itemnumber IS NOT NULL AND '.$exclude_material,$from,$to,@bind,@excluded_types);
    my $previous_checkouts = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$previous_from,$previous_to,@bind);
    my $checkouts_change = $previous_checkouts ? 100 * ( $checkouts - $previous_checkouts ) / $previous_checkouts : undef;
    my $flow = $q->(q{
        SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,
          SUM(type='issue') AS issues, SUM(type='renew') AS renewals, SUM(type='return') AS returns, COUNT(*) AS events
        FROM statistics WHERE datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}
        . ($branch ? ' AND branch = ?' : '') . q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month}, $from,$to,@bind);
    my $history = $q->(q{SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,SUM(type='issue') AS issues,COUNT(*) AS events
        FROM statistics WHERE datetime >= DATE_SUB(DATE_FORMAT(?, '%Y-%m-01'), INTERVAL 35 MONTH)
        AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : '').q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month},$to,$to,@bind);
    my $same_period_last_year = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='issue' AND datetime >= DATE_SUB(?, INTERVAL 1 YEAR) AND datetime < DATE_ADD(DATE_SUB(?, INTERVAL 1 YEAR), INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$from,$to,@bind);
    my $same_period_change = $same_period_last_year ? 100 * ( $checkouts - $same_period_last_year ) / $same_period_last_year : undef;
    my $due_now = $scalar->('SELECT COUNT(*) FROM issues WHERE date_due < CURDATE()'.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $overdue_bands = $q->(q{SELECT
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS days_1_7,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 8 AND 30 THEN 1 ELSE 0 END) AS days_8_30,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 31 AND 90 THEN 1 ELSE 0 END) AS days_31_90,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) > 90 THEN 1 ELSE 0 END) AS days_over_90
        FROM issues WHERE date_due < CURDATE()}.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $active = $scalar->(q{SELECT COUNT(DISTINCT s.borrowernumber) FROM statistics s WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : ''),$from,$to,@bind);
    my $active_valid = $scalar->(q{SELECT COUNT(DISTINCT s.borrowernumber) FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY) AND (b.dateexpiry IS NULL OR b.dateexpiry >= CURDATE())}.($branch ? ' AND s.branch = ?' : ''),$from,$to,@bind);
    my $previous_active = $scalar->(q{SELECT COUNT(DISTINCT s.borrowernumber) FROM statistics s WHERE s.type IN ('issue','renew') AND s.borrowernumber IS NOT NULL AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : ''),$previous_from,$previous_to,@bind);
    my $returning_active = $scalar->(q{SELECT COUNT(DISTINCT cur.borrowernumber) FROM statistics cur JOIN statistics prev ON prev.borrowernumber=cur.borrowernumber AND prev.type IN ('issue','renew') AND prev.borrowernumber IS NOT NULL AND prev.datetime >= ? AND prev.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND prev.branch = ?' : '').q{ WHERE cur.type IN ('issue','renew') AND cur.borrowernumber IS NOT NULL AND cur.datetime >= ? AND cur.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND cur.branch = ?' : ''),$previous_from,$previous_to,@bind,$from,$to,@bind);
    my $can_view_names = _can_view_names();
    my $top_borrowers = $q->(q{SELECT b.borrowernumber,CONCAT_WS(' ',b.firstname,b.surname) AS borrower,COUNT(*) AS checkouts FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').q{ GROUP BY b.borrowernumber,b.firstname,b.surname ORDER BY checkouts DESC,b.surname,b.firstname LIMIT 10},$from,$to,@bind);
    unless ($can_view_names) { my $n=0; $_->{borrower}='Socio '.++$n for @$top_borrowers; }
    my $inactive = $scalar->(q{SELECT COUNT(*) FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE }. $exclude_material . q{ AND NOT EXISTS (SELECT 1 FROM statistics s WHERE s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY))}.($branch ? ' AND i.homebranch = ?' : ''),@excluded_types,$from,$to,@bind);
    my $collection = $scalar->('SELECT COUNT(*) FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE '.$exclude_material.($branch ? ' AND i.homebranch = ?' : ''),@excluded_types,@bind);
    my $titles = $scalar->('SELECT COUNT(DISTINCT i.biblionumber) FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE '.$exclude_material.($branch ? ' AND i.homebranch = ?' : ''),@excluded_types,@bind);
    my $circulated_titles = $scalar->(q{SELECT COUNT(DISTINCT i.biblionumber) FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ? AND i.homebranch = ?' : '').' AND '.$exclude_material,$from,$to,$branch ? ($branch,$branch) : (),@excluded_types);
    my $title_movement = $titles ? 100 * $circulated_titles / $titles : 0;
    my $borrowers = $scalar->('SELECT COUNT(*) FROM borrowers WHERE (dateexpiry IS NULL OR dateexpiry >= CURDATE())'.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $eligible_filter = @eligible_categories ? ' AND categorycode IN ('.join(',',('?') x @eligible_categories).')' : '';
    my $eligible_borrowers = $scalar->('SELECT COUNT(*) FROM borrowers WHERE (dateexpiry IS NULL OR dateexpiry >= CURDATE())'.$eligible_filter.($branch ? ' AND branchcode = ?' : ''),@eligible_categories,@bind);
    my $active_eligible = $scalar->(q{SELECT COUNT(DISTINCT s.borrowernumber) FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY) AND (b.dateexpiry IS NULL OR b.dateexpiry >= CURDATE())}.($branch ? ' AND s.branch = ?' : '').$eligible_filter,$from,$to,@bind,@eligible_categories);
    my $local_use = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='localuse' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$from,$to,@bind);
    my $zero_searches = $q->(q{SELECT query_desc AS search_term,COUNT(*) AS searches FROM search_history WHERE type='biblio' AND total=0 AND time >= ? AND time < DATE_ADD(?, INTERVAL 1 DAY) GROUP BY query_desc HAVING COUNT(*) >= 2 ORDER BY searches DESC,search_term LIMIT 20},$from,$to);
    my $new_borrowers_count = $scalar->('SELECT COUNT(*) FROM borrowers WHERE dateenrolled >= ? AND dateenrolled < DATE_ADD(?, INTERVAL 1 DAY)'.($branch ? ' AND branchcode = ?' : ''),$from,$to,@bind);
    my $new_borrowers_active = $scalar->(q{SELECT COUNT(DISTINCT b.borrowernumber) FROM borrowers b JOIN statistics s ON s.borrowernumber=b.borrowernumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').q{ WHERE b.dateenrolled >= ? AND b.dateenrolled < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND b.branchcode = ?' : ''),$from,$to,@bind,$from,$to,@bind);
    my $fines = $dbh->selectrow_hashref(q{SELECT COALESCE(SUM(amount),0) AS generated, COALESCE(SUM(amount-amountoutstanding),0) AS paid, COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branchcode = ?' : ''), undef, $from,$to,@bind);
    my $cataloguers = $q->(q{SELECT al.user, COALESCE(CONCAT(b.surname, ', ', b.firstname), CONCAT('Usuario ', al.user)) AS cataloguer, COUNT(*) AS records
        FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user
        WHERE al.module='CATALOGUING' AND al.action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}
        . ($branch ? ' AND b.branchcode = ?' : '') . ' GROUP BY al.user, b.surname, b.firstname ORDER BY records DESC LIMIT 10',$from,$to,@bind);
    unless ($can_view_names) { my $n=0; $_->{cataloguer}='Catalogador '.++$n for @$cataloguers; }
    my $monthly_cataloguing = $q->(q{SELECT DATE_FORMAT(al.timestamp,'%Y-%m') AS month, COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND b.branchcode = ?' : '').q{ GROUP BY DATE_FORMAT(al.timestamp,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $monthly_fines = $q->(q{SELECT DATE_FORMAT(date,'%Y-%m') AS month,COALESCE(SUM(amount),0) AS generated,COALESCE(SUM(amount-amountoutstanding),0) AS paid,COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branchcode = ?' : '').q{ GROUP BY DATE_FORMAT(date,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $itemtype_use = $q->(q{SELECT COALESCE(it.description,COALESCE(i.itype,bi.itemtype,'Sin tipo')) AS item_type,
        COUNT(DISTINCT i.itemnumber) AS copies,COUNT(s.itemnumber) AS checkouts,
        ROUND(COUNT(s.itemnumber)/GREATEST(COUNT(DISTINCT i.itemnumber),1),2) AS turnover
        FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber
        LEFT JOIN itemtypes it ON it.itemtype=COALESCE(i.itype,bi.itemtype)
        LEFT JOIN statistics s ON s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND s.branch = ?' : '').
        ' WHERE '.$exclude_material.($branch ? ' AND i.homebranch = ?' : '').
        q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,@excluded_types,($branch ? $branch : ()));
    my $itemtype_use_equipment = @excluded_types ? $q->(q{SELECT COALESCE(it.description,COALESCE(i.itype,bi.itemtype,'Sin tipo')) AS item_type,
        COUNT(DISTINCT i.itemnumber) AS copies,COUNT(s.itemnumber) AS checkouts,
        ROUND(COUNT(s.itemnumber)/GREATEST(COUNT(DISTINCT i.itemnumber),1),2) AS turnover
        FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber
        LEFT JOIN itemtypes it ON it.itemtype=COALESCE(i.itype,bi.itemtype)
        LEFT JOIN statistics s ON s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND s.branch = ?' : '').' WHERE '.$equipment_material.($branch ? ' AND i.homebranch = ?' : '').
        q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,@excluded_types,($branch ? $branch : ())) : [];
    my $day_hour = $q->(q{SELECT DAYOFWEEK(datetime)-1 AS weekday,HOUR(datetime) AS hour,COUNT(*) AS checkouts
        FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND branch = ?' : '').q{ GROUP BY DAYOFWEEK(datetime),HOUR(datetime) ORDER BY weekday,hour},$from,$to,@bind);
    my $borrowers_by_category = $q->(q{SELECT COALESCE(c.description,b.categorycode,'Sin categoría') AS category,
        COUNT(DISTINCT s.borrowernumber) AS active_borrowers FROM statistics s
        LEFT JOIN borrowers b ON b.borrowernumber=s.borrowernumber
        LEFT JOIN categories c ON c.categorycode=b.categorycode
        WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND s.branch = ?' : '').q{ GROUP BY category ORDER BY active_borrowers DESC},$from,$to,@bind);
    my $new_borrowers = $q->(q{SELECT DATE_FORMAT(dateenrolled,'%Y-%m') AS month,COUNT(*) AS new_borrowers
        FROM borrowers WHERE dateenrolled >= ? AND dateenrolled < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND branchcode = ?' : '').q{ GROUP BY DATE_FORMAT(dateenrolled,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $bestsellers = $q->(q{SELECT b.title, COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').' AND '.$exclude_material.q{ GROUP BY b.biblionumber,b.title ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind,@excluded_types);
    my $top_equipment = @excluded_types ? $q->(q{SELECT b.title,COUNT(*) AS checkouts,COALESCE(i.itype,bi.itemtype) AS item_type FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').' AND '.$equipment_material.q{ GROUP BY b.biblionumber,b.title,item_type ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind,@excluded_types) : [];
    my $inactive_by_class = $q->(q{SELECT CASE WHEN COALESCE(i.itemcallnumber,'') REGEXP '^[0-9]' THEN LEFT(i.itemcallnumber,3) ELSE 'Sin clasificación decimal' END AS classification,COUNT(*) AS idle_copies FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE }. $exclude_material . q{ AND NOT EXISTS (SELECT 1 FROM statistics s WHERE s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= DATE_SUB(?, INTERVAL }.$idle_years.q{ YEAR))}.($branch ? ' AND i.homebranch = ?' : '').q{ GROUP BY classification ORDER BY idle_copies DESC LIMIT 20},@excluded_types,$to,@bind);
    my $loans_by_class = $q->(q{SELECT CASE WHEN COALESCE(i.itemcallnumber,'') REGEXP '^[0-9]' THEN LEFT(i.itemcallnumber,3) ELSE 'Sin clasificación decimal' END AS classification,COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ? AND i.homebranch = ?' : '').' AND '.$exclude_material.q{ GROUP BY classification ORDER BY checkouts DESC LIMIT 20},$from,$to,$branch ? ($branch,$branch) : (),@excluded_types);
    my $overdue_list = $q->(q{SELECT b.title,CONCAT_WS(' ',p.firstname,p.surname) AS patron,i.date_due,DATEDIFF(CURDATE(),i.date_due) AS days_overdue FROM issues i JOIN items it ON it.itemnumber=i.itemnumber JOIN biblio b ON b.biblionumber=it.biblionumber JOIN borrowers p ON p.borrowernumber=i.borrowernumber WHERE i.date_due < CURDATE()}.($branch ? ' AND i.branchcode = ?' : '').q{ ORDER BY days_overdue DESC},@bind);
    my $holds = $dbh->selectrow_hashref(q{SELECT COUNT(*) AS waiting,COALESCE(ROUND(AVG(DATEDIFF(CURDATE(),reservedate)),1),0) AS avg_wait FROM reserves WHERE found IS NULL AND cancellationdate IS NULL AND (expirationdate IS NULL OR expirationdate >= CURDATE())}.($branch ? ' AND branchcode = ?' : ''),undef,@bind);
    my $branch_comparison = $branch ? [] : $q->(q{SELECT br.branchcode,br.branchname,COALESCE(SUM(s.type='issue'),0) AS checkouts FROM branches br LEFT JOIN statistics s ON s.branch=br.branchcode AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY) GROUP BY br.branchcode,br.branchname ORDER BY checkouts DESC,br.branchname},$from,$to);
    my $same_year_from=dt_from_string($from)->subtract(years=>1)->ymd;
    my $same_year_to=dt_from_string($to)->subtract(years=>1)->ymd;
    my $payload = { from=>$from,to=>$to,previous_from=>$previous_from,previous_to=>$previous_to,same_year_from=>$same_year_from,same_year_to=>$same_year_to,idle_years=>$idle_years,
        kpis=>{ checkouts=>$checkouts,bibliographic_checkouts=>$bibliographic_checkouts,checkouts_change=>$checkouts_change,previous_checkouts=>$previous_checkouts,
        overdue=>$due_now,active_borrowers=>$active,idle_items=>$inactive,items=>$collection,titles=>$titles,circulated_titles=>$circulated_titles,title_movement=>$title_movement,borrowers=>$borrowers,
        fines_generated=>0+($fines->{generated}||0),fines_paid=>0+($fines->{paid}||0),fines_outstanding=>0+($fines->{outstanding}||0),
        same_period_last_year=>$same_period_last_year,same_period_change=>$same_period_change,
        checkout_goal=>$checkout_goal,checkout_goal_progress=>$checkout_goal ? 100*$checkouts/$checkout_goal : undef,
        active_share=>$borrowers ? 100*$active_valid/$borrowers : 0,previous_active=>$previous_active,
        eligible_borrowers=>$eligible_borrowers,active_eligible=>$active_eligible,eligible_active_share=>$eligible_borrowers ? 100*$active_eligible/$eligible_borrowers : 0,local_use=>$local_use,
        returning_active=>$returning_active,returning_rate=>$previous_active ? 100*$returning_active/$previous_active : undef,
        new_borrowers=>$new_borrowers_count,new_borrowers_active=>$new_borrowers_active,
        new_borrower_activation=>$new_borrowers_count ? 100*$new_borrowers_active/$new_borrowers_count : undef },
        flow=>$flow,history=>$history,cataloguers=>$cataloguers,cataloguing=>$monthly_cataloguing,fines=>$monthly_fines,top_titles=>$bestsellers,top_equipment=>$top_equipment,
        overdue_bands=>$overdue_bands,itemtype_use=>$itemtype_use,itemtype_use_equipment=>$itemtype_use_equipment,day_hour=>$day_hour,top_borrowers=>$top_borrowers,zero_searches=>$zero_searches,
        borrowers_by_category=>$borrowers_by_category,new_borrowers=>$new_borrowers,inactive_by_class=>$inactive_by_class,loans_by_class=>$loans_by_class,overdue_list=>$can_view_names ? $overdue_list : [],holds=>$holds,branch_comparison=>$branch_comparison };
    $self->output( encode_json($payload), 'json', undef, { force_no_caching => 1 } );
}

sub _csv {
    my ( $self, $cgi ) = @_;
    my $data = $self->_get_data($cgi);
    my $name = $cgi->param('dataset') || 'circulation';
    my %sets = ( circulation=>$data->{flow}, history=>$data->{history}, branch_comparison=>$data->{branch_comparison}, zero_searches=>$data->{zero_searches}, cataloguing=>$data->{cataloguing}, cataloguers=>$data->{cataloguers}, top_titles=>$data->{top_titles}, top_equipment=>$data->{top_equipment}, inactive_by_class=>$data->{inactive_by_class}, loans_by_class=>$data->{loans_by_class}, overdue_list=>$data->{overdue_list}, fines=>$data->{fines}, overdue_bands=>$data->{overdue_bands}, itemtype_use=>$data->{itemtype_use}, itemtype_equipment=>$data->{itemtype_use_equipment}, day_hour=>$data->{day_hour}, borrowers_by_category=>$data->{borrowers_by_category}, new_borrowers=>$data->{new_borrowers}, top_borrowers=>$data->{top_borrowers} );
    $name = 'circulation' unless exists $sets{$name};
    my $rows = $sets{$name} || [];
    my @cols = @$rows ? sort keys %{ $rows->[0] } : ('sin_datos');
    my $csv = join(',', map { _csv_cell($_) } @cols) . "\r\n";
    for my $row (@$rows) { $csv .= join(',', map { _csv_cell($row->{$_}) } @cols) . "\r\n"; }
    print $cgi->header(-type=>'text/csv; charset=utf-8',-attachment=>"koha-dashboard-$name.csv",-charset=>'utf-8');
    print "\x{FEFF}$csv";
}

sub _get_data {
    my ($self,$cgi)=@_;
    # Reuse the data query while capturing its JSON response for CSV export.
    require JSON;
    my ($from,$to,$branch)=_range($cgi);
    my $idle_years=$cgi->param('idle_years')||3;
    $idle_years=3 unless $idle_years =~ /\A(?:1|3|5)\z/;
    my $dbh=C4::Context->dbh;
    my @bind=$branch ? ($branch) : ();
    my @excluded=$self->_excluded_itemtypes;
    my $exclude_material=@excluded ? 'COALESCE(i.itype,bi.itemtype,\'\') NOT IN ('.join(',',('?') x @excluded).')' : '1=1';
    my $equipment_material=@excluded ? 'COALESCE(i.itype,bi.itemtype,\'\') IN ('.join(',',('?') x @excluded).')' : '1=0';
    my $q=sub { my($sql,@args)=@_; $dbh->selectall_arrayref($sql,{Slice=>{}},@args) };
    my $flow=$q->(q{SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,SUM(type='issue') AS issues,SUM(type='renew') AS renewals,SUM(type='return') AS returns,COUNT(*) AS events FROM statistics WHERE datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branch = ?':'').q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $history=$q->(q{SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,SUM(type='issue') AS issues,COUNT(*) AS events FROM statistics WHERE datetime >= DATE_SUB(DATE_FORMAT(?, '%Y-%m-01'), INTERVAL 35 MONTH) AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branch = ?':'').q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month},$to,$to,@bind);
    my $branch_comparison=$branch ? [] : $q->(q{SELECT br.branchcode,br.branchname,COALESCE(SUM(s.type='issue'),0) AS checkouts FROM branches br LEFT JOIN statistics s ON s.branch=br.branchcode AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY) GROUP BY br.branchcode,br.branchname ORDER BY checkouts DESC,br.branchname},$from,$to);
    my $zero_searches=$q->(q{SELECT query_desc AS search_term,COUNT(*) AS searches FROM search_history WHERE type='biblio' AND total=0 AND time >= ? AND time < DATE_ADD(?, INTERVAL 1 DAY) GROUP BY query_desc HAVING COUNT(*) >= 2 ORDER BY searches DESC,search_term LIMIT 20},$from,$to);
    my $cataloguing=$q->(q{SELECT DATE_FORMAT(al.timestamp,'%Y-%m') AS month,COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND b.branchcode = ?':'').q{ GROUP BY DATE_FORMAT(al.timestamp,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $cataloguers=$q->(q{SELECT al.user,COALESCE(CONCAT(b.surname, ', ', b.firstname),CONCAT('Usuario ',al.user)) AS cataloguer,COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND al.action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND b.branchcode = ?':'').q{ GROUP BY al.user,b.surname,b.firstname ORDER BY records DESC LIMIT 10},$from,$to,@bind);
    if (!_can_view_names()) { my $n=0; $_->{cataloguer}='Catalogador '.++$n for @$cataloguers; }
    my $fines=$q->(q{SELECT DATE_FORMAT(date,'%Y-%m') AS month,COALESCE(SUM(amount),0) AS generated,COALESCE(SUM(amount-amountoutstanding),0) AS paid,COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branchcode = ?':'').q{ GROUP BY DATE_FORMAT(date,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $top_titles=$q->(q{SELECT b.title,COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').' AND '.$exclude_material.q{ GROUP BY b.biblionumber,b.title ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind,@excluded);
    my $top_equipment=@excluded ? $q->(q{SELECT b.title,COUNT(*) AS checkouts,COALESCE(i.itype,bi.itemtype) AS item_type FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').' AND '.$equipment_material.q{ GROUP BY b.biblionumber,b.title,item_type ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind,@excluded) : [];
    my $inactive_by_class=$q->(q{SELECT CASE WHEN COALESCE(i.itemcallnumber,'') REGEXP '^[0-9]' THEN LEFT(i.itemcallnumber,3) ELSE 'Sin clasificación decimal' END AS classification,COUNT(*) AS idle_copies FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE }. $exclude_material . q{ AND NOT EXISTS (SELECT 1 FROM statistics s WHERE s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= DATE_SUB(?, INTERVAL }.$idle_years.q{ YEAR))}.($branch?' AND i.homebranch = ?':'').q{ GROUP BY classification ORDER BY idle_copies DESC LIMIT 20},@excluded,$to,@bind);
    my $loans_by_class=$q->(q{SELECT CASE WHEN COALESCE(i.itemcallnumber,'') REGEXP '^[0-9]' THEN LEFT(i.itemcallnumber,3) ELSE 'Sin clasificación decimal' END AS classification,COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ? AND i.homebranch = ?':'').' AND '.$exclude_material.q{ GROUP BY classification ORDER BY checkouts DESC LIMIT 20},$from,$to,$branch?($branch,$branch):(),@excluded);
    my $overdue_bands=$q->(q{SELECT
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS days_1_7,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 8 AND 30 THEN 1 ELSE 0 END) AS days_8_30,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 31 AND 90 THEN 1 ELSE 0 END) AS days_31_90,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) > 90 THEN 1 ELSE 0 END) AS days_over_90
        FROM issues WHERE date_due < CURDATE()}.($branch?' AND branchcode = ?':''),@bind);
    my $itemtype_sql=q{SELECT COALESCE(it.description,COALESCE(i.itype,bi.itemtype,'Sin tipo')) AS item_type,COUNT(DISTINCT i.itemnumber) AS copies,COUNT(s.itemnumber) AS checkouts,ROUND(COUNT(s.itemnumber)/GREATEST(COUNT(DISTINCT i.itemnumber),1),2) AS turnover FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber LEFT JOIN itemtypes it ON it.itemtype=COALESCE(i.itype,bi.itemtype) LEFT JOIN statistics s ON s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'');
    my $itemtype_use=$q->($itemtype_sql.' WHERE '.$exclude_material.($branch?' AND i.homebranch = ?':'').q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,@excluded,($branch?$branch:()));
    my $itemtype_use_equipment=@excluded ? $q->($itemtype_sql.' WHERE '.$equipment_material.($branch?' AND i.homebranch = ?':'').q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,@excluded,($branch?$branch:())) : [];
    my $day_hour=$q->(q{SELECT DAYOFWEEK(datetime)-1 AS weekday,HOUR(datetime) AS hour,COUNT(*) AS checkouts FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branch = ?':'').q{ GROUP BY DAYOFWEEK(datetime),HOUR(datetime) ORDER BY weekday,hour},$from,$to,@bind);
    my $borrowers_by_category=$q->(q{SELECT COALESCE(c.description,b.categorycode,'Sin categoría') AS category,COUNT(DISTINCT s.borrowernumber) AS active_borrowers FROM statistics s LEFT JOIN borrowers b ON b.borrowernumber=s.borrowernumber LEFT JOIN categories c ON c.categorycode=b.categorycode WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').q{ GROUP BY category ORDER BY active_borrowers DESC},$from,$to,@bind);
    my $new_borrowers=$q->(q{SELECT DATE_FORMAT(dateenrolled,'%Y-%m') AS month,COUNT(*) AS new_borrowers FROM borrowers WHERE dateenrolled >= ? AND dateenrolled < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branchcode = ?':'').q{ GROUP BY DATE_FORMAT(dateenrolled,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $top_borrowers=$q->(q{SELECT CONCAT_WS(' ',b.firstname,b.surname) AS borrower,COUNT(*) AS checkouts FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').q{ GROUP BY b.borrowernumber,b.firstname,b.surname ORDER BY checkouts DESC,b.surname,b.firstname LIMIT 10},$from,$to,@bind);
    unless (_can_view_names()) { my $n=0; $_->{borrower}='Socio '.++$n for @$top_borrowers; }
    my $overdue_list=_can_view_names() ? $q->(q{SELECT b.title,CONCAT_WS(' ',p.firstname,p.surname) AS patron,i.date_due,DATEDIFF(CURDATE(),i.date_due) AS days_overdue FROM issues i JOIN items it ON it.itemnumber=i.itemnumber JOIN biblio b ON b.biblionumber=it.biblionumber JOIN borrowers p ON p.borrowernumber=i.borrowernumber WHERE i.date_due < CURDATE()}.($branch?' AND i.branchcode = ?':'').q{ ORDER BY days_overdue DESC},@bind) : [];
    return {flow=>$flow,history=>$history,branch_comparison=>$branch_comparison,zero_searches=>$zero_searches,cataloguing=>$cataloguing,cataloguers=>$cataloguers,top_titles=>$top_titles,top_equipment=>$top_equipment,inactive_by_class=>$inactive_by_class,loans_by_class=>$loans_by_class,overdue_list=>$overdue_list,fines=>$fines,overdue_bands=>$overdue_bands,itemtype_use=>$itemtype_use,itemtype_use_equipment=>$itemtype_use_equipment,day_hour=>$day_hour,borrowers_by_category=>$borrowers_by_category,new_borrowers=>$new_borrowers,top_borrowers=>$top_borrowers};
}

sub _csv_cell {
    my ($value)=@_;
    $value='' unless defined $value;
    $value="$value";
    $value="'$value" if $value =~ /^[=+\-\@\t\r]/;
    $value =~ s/"/""/g;
    return '"'.$value.'"';
}

1;

