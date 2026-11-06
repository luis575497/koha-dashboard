package Koha::Plugin::Com::Bibliobytes::Dashboard;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use Koha::DateUtils qw(dt_from_string);
use JSON qw(encode_json);
use C4::Context;
use CGI qw(-utf8);

our $VERSION = '1.3.0';

our $metadata = {
    name            => 'Dashboard bibliotecario',
    author          => 'Bibliobytes',
    description     => 'Dashboard bibliotecario con movimiento de colección, circulación, usuarios, catalogación y exportación CSV.',
    date_authored   => '2026-11-06',
    date_updated    => '2026-11-06',
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
    $template->param( branches => $branches, plugin_url => $self->get_plugin_http_path );
    $self->output_html( $template->output );
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
    my $q = sub { my ($sql,@args)=@_; return $dbh->selectall_arrayref($sql,{Slice=>{}},@args) };
    my $scalar = sub { my ($sql,@args)=@_; my ($v)=$dbh->selectrow_array($sql,undef,@args); return 0 + ($v || 0) };
    my $from_dt = dt_from_string($from);
    my $to_dt   = dt_from_string($to);
    my $period_days = int( ( $to_dt->epoch - $from_dt->epoch ) / 86400 ) + 1;
    my $previous_to = $from_dt->clone->subtract( days => 1 )->ymd;
    my $previous_from = dt_from_string($previous_to)->subtract( days => $period_days - 1 )->ymd;
    my $checkouts = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$from,$to,@bind);
    my $previous_checkouts = $scalar->(q{SELECT COUNT(*) FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branch = ?' : ''),$previous_from,$previous_to,@bind);
    my $checkouts_change = $previous_checkouts ? 100 * ( $checkouts - $previous_checkouts ) / $previous_checkouts : undef;
    my $flow = $q->(q{
        SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,
          SUM(type='issue') AS issues, SUM(type='renew') AS renewals, SUM(type='return') AS returns
        FROM statistics WHERE datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}
        . ($branch ? ' AND branch = ?' : '') . q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month}, $from,$to,@bind);
    my $due_now = $scalar->('SELECT COUNT(*) FROM issues WHERE date_due < CURDATE()'.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $overdue_bands = $q->(q{SELECT
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS days_1_7,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 8 AND 30 THEN 1 ELSE 0 END) AS days_8_30,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 31 AND 90 THEN 1 ELSE 0 END) AS days_31_90,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) > 90 THEN 1 ELSE 0 END) AS days_over_90
        FROM issues WHERE date_due < CURDATE()}.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $active = $scalar->(q{SELECT COUNT(DISTINCT s.borrowernumber) FROM statistics s WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : ''),$from,$to,@bind);
    my $top_borrowers = $q->(q{SELECT CONCAT_WS(' ',b.firstname,b.surname) AS borrower,COUNT(*) AS checkouts FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').q{ GROUP BY b.borrowernumber,b.firstname,b.surname ORDER BY checkouts DESC,b.surname,b.firstname LIMIT 10},$from,$to,@bind);
    my $inactive = $scalar->(q{SELECT COUNT(*) FROM items i WHERE NOT EXISTS (SELECT 1 FROM statistics s WHERE s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY))}.($branch ? ' AND i.homebranch = ?' : ''),$from,$to,@bind);
    my $collection = $scalar->('SELECT COUNT(*) FROM items'.($branch ? ' WHERE homebranch = ?' : ''),@bind);
    my $titles = $scalar->('SELECT COUNT(DISTINCT biblionumber) FROM items'.($branch ? ' WHERE homebranch = ?' : ''),@bind);
    my $circulated_titles = $scalar->(q{SELECT COUNT(DISTINCT i.biblionumber) FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ? AND i.homebranch = ?' : ''),$from,$to,$branch ? ($branch,$branch) : ());
    my $title_movement = $titles ? 100 * $circulated_titles / $titles : 0;
    my $borrowers = $scalar->('SELECT COUNT(*) FROM borrowers WHERE (dateexpiry IS NULL OR dateexpiry >= CURDATE())'.($branch ? ' AND branchcode = ?' : ''),@bind);
    my $fines = $dbh->selectrow_hashref(q{SELECT COALESCE(SUM(amount),0) AS generated, COALESCE(SUM(amount-amountoutstanding),0) AS paid, COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branchcode = ?' : ''), undef, $from,$to,@bind);
    my $cataloguers = $q->(q{SELECT al.user, COALESCE(CONCAT(b.surname, ', ', b.firstname), CONCAT('Usuario ', al.user)) AS cataloguer, COUNT(*) AS records
        FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user
        WHERE al.module='CATALOGUING' AND al.action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}
        . ($branch ? ' AND b.branchcode = ?' : '') . ' GROUP BY al.user, b.surname, b.firstname ORDER BY records DESC LIMIT 10',$from,$to,@bind);
    my $monthly_cataloguing = $q->(q{SELECT DATE_FORMAT(al.timestamp,'%Y-%m') AS month, COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND b.branchcode = ?' : '').q{ GROUP BY DATE_FORMAT(al.timestamp,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $monthly_fines = $q->(q{SELECT DATE_FORMAT(date,'%Y-%m') AS month,COALESCE(SUM(amount),0) AS generated,COALESCE(SUM(amount-amountoutstanding),0) AS paid,COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND branchcode = ?' : '').q{ GROUP BY DATE_FORMAT(date,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $itemtype_use = $q->(q{SELECT COALESCE(it.description,COALESCE(i.itype,bi.itemtype,'Sin tipo')) AS item_type,
        COUNT(DISTINCT i.itemnumber) AS copies,COUNT(s.itemnumber) AS checkouts,
        ROUND(COUNT(s.itemnumber)/GREATEST(COUNT(DISTINCT i.itemnumber),1),2) AS turnover
        FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber
        LEFT JOIN itemtypes it ON it.itemtype=COALESCE(i.itype,bi.itemtype)
        LEFT JOIN statistics s ON s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.
        ($branch ? ' AND s.branch = ?' : '').
        ($branch ? ' WHERE i.homebranch = ?' : '').
        q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,($branch ? $branch : ()));
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
    my $bestsellers = $q->(q{SELECT b.title, COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch ? ' AND s.branch = ?' : '').q{ GROUP BY b.biblionumber,b.title ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind);
    my $payload = { from=>$from,to=>$to,previous_from=>$previous_from,previous_to=>$previous_to,
        kpis=>{ checkouts=>$checkouts,checkouts_change=>$checkouts_change,previous_checkouts=>$previous_checkouts,
        overdue=>$due_now,active_borrowers=>$active,idle_items=>$inactive,items=>$collection,titles=>$titles,circulated_titles=>$circulated_titles,title_movement=>$title_movement,borrowers=>$borrowers,
        fines_generated=>0+($fines->{generated}||0),fines_paid=>0+($fines->{paid}||0),fines_outstanding=>0+($fines->{outstanding}||0) },
        flow=>$flow,cataloguers=>$cataloguers,cataloguing=>$monthly_cataloguing,fines=>$monthly_fines,top_titles=>$bestsellers,
        overdue_bands=>$overdue_bands,itemtype_use=>$itemtype_use,day_hour=>$day_hour,top_borrowers=>$top_borrowers,
        borrowers_by_category=>$borrowers_by_category,new_borrowers=>$new_borrowers };
    $self->output( encode_json($payload), 'json', undef, { force_no_caching => 1 } );
}

sub _csv {
    my ( $self, $cgi ) = @_;
    my $data = $self->_get_data($cgi);
    my $name = $cgi->param('dataset') || 'circulation';
    my %sets = ( circulation=>$data->{flow}, cataloguing=>$data->{cataloguing}, cataloguers=>$data->{cataloguers}, top_titles=>$data->{top_titles}, fines=>$data->{fines}, overdue_bands=>$data->{overdue_bands}, itemtype_use=>$data->{itemtype_use}, day_hour=>$data->{day_hour}, borrowers_by_category=>$data->{borrowers_by_category}, new_borrowers=>$data->{new_borrowers}, top_borrowers=>$data->{top_borrowers} );
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
    my $dbh=C4::Context->dbh;
    my @bind=$branch ? ($branch) : ();
    my $q=sub { my($sql,@args)=@_; $dbh->selectall_arrayref($sql,{Slice=>{}},@args) };
    my $flow=$q->(q{SELECT DATE_FORMAT(datetime,'%Y-%m') AS month,SUM(type='issue') AS issues,SUM(type='renew') AS renewals,SUM(type='return') AS returns FROM statistics WHERE datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branch = ?':'').q{ GROUP BY DATE_FORMAT(datetime,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $cataloguing=$q->(q{SELECT DATE_FORMAT(al.timestamp,'%Y-%m') AS month,COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND b.branchcode = ?':'').q{ GROUP BY DATE_FORMAT(al.timestamp,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $cataloguers=$q->(q{SELECT al.user,COALESCE(CONCAT(b.surname, ', ', b.firstname),CONCAT('Usuario ',al.user)) AS cataloguer,COUNT(*) AS records FROM action_logs al LEFT JOIN borrowers b ON b.borrowernumber=al.user WHERE al.module='CATALOGUING' AND al.action='ADD' AND al.info='biblio' AND al.timestamp >= ? AND al.timestamp < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND b.branchcode = ?':'').q{ GROUP BY al.user,b.surname,b.firstname ORDER BY records DESC LIMIT 10},$from,$to,@bind);
    my $fines=$q->(q{SELECT DATE_FORMAT(date,'%Y-%m') AS month,COALESCE(SUM(amount),0) AS generated,COALESCE(SUM(amount-amountoutstanding),0) AS paid,COALESCE(SUM(amountoutstanding),0) AS outstanding FROM accountlines WHERE debit_type_code='OVERDUE' AND date >= ? AND date < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branchcode = ?':'').q{ GROUP BY DATE_FORMAT(date,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $top_titles=$q->(q{SELECT b.title,COUNT(*) AS checkouts FROM statistics s JOIN items i ON i.itemnumber=s.itemnumber JOIN biblio b ON b.biblionumber=i.biblionumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').q{ GROUP BY b.biblionumber,b.title ORDER BY checkouts DESC LIMIT 10},$from,$to,@bind);
    my $overdue_bands=$q->(q{SELECT
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 1 AND 7 THEN 1 ELSE 0 END) AS days_1_7,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 8 AND 30 THEN 1 ELSE 0 END) AS days_8_30,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) BETWEEN 31 AND 90 THEN 1 ELSE 0 END) AS days_31_90,
        SUM(CASE WHEN DATEDIFF(CURDATE(),date_due) > 90 THEN 1 ELSE 0 END) AS days_over_90
        FROM issues WHERE date_due < CURDATE()}.($branch?' AND branchcode = ?':''),@bind);
    my $itemtype_use=$q->(q{SELECT COALESCE(it.description,COALESCE(i.itype,bi.itemtype,'Sin tipo')) AS item_type,COUNT(DISTINCT i.itemnumber) AS copies,COUNT(s.itemnumber) AS checkouts,ROUND(COUNT(s.itemnumber)/GREATEST(COUNT(DISTINCT i.itemnumber),1),2) AS turnover FROM items i LEFT JOIN biblioitems bi ON bi.biblioitemnumber=i.biblioitemnumber LEFT JOIN itemtypes it ON it.itemtype=COALESCE(i.itype,bi.itemtype) LEFT JOIN statistics s ON s.itemnumber=i.itemnumber AND s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').($branch?' WHERE i.homebranch = ?':'').q{ GROUP BY item_type ORDER BY turnover DESC,copies DESC LIMIT 12},$from,$to,@bind,($branch?$branch:()));
    my $day_hour=$q->(q{SELECT DAYOFWEEK(datetime)-1 AS weekday,HOUR(datetime) AS hour,COUNT(*) AS checkouts FROM statistics WHERE type='issue' AND datetime >= ? AND datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branch = ?':'').q{ GROUP BY DAYOFWEEK(datetime),HOUR(datetime) ORDER BY weekday,hour},$from,$to,@bind);
    my $borrowers_by_category=$q->(q{SELECT COALESCE(c.description,b.categorycode,'Sin categoría') AS category,COUNT(DISTINCT s.borrowernumber) AS active_borrowers FROM statistics s LEFT JOIN borrowers b ON b.borrowernumber=s.borrowernumber LEFT JOIN categories c ON c.categorycode=b.categorycode WHERE s.type IN ('issue','renew') AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').q{ GROUP BY category ORDER BY active_borrowers DESC},$from,$to,@bind);
    my $new_borrowers=$q->(q{SELECT DATE_FORMAT(dateenrolled,'%Y-%m') AS month,COUNT(*) AS new_borrowers FROM borrowers WHERE dateenrolled >= ? AND dateenrolled < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND branchcode = ?':'').q{ GROUP BY DATE_FORMAT(dateenrolled,'%Y-%m') ORDER BY month},$from,$to,@bind);
    my $top_borrowers=$q->(q{SELECT CONCAT_WS(' ',b.firstname,b.surname) AS borrower,COUNT(*) AS checkouts FROM statistics s JOIN borrowers b ON b.borrowernumber=s.borrowernumber WHERE s.type='issue' AND s.datetime >= ? AND s.datetime < DATE_ADD(?, INTERVAL 1 DAY)}.($branch?' AND s.branch = ?':'').q{ GROUP BY b.borrowernumber,b.firstname,b.surname ORDER BY checkouts DESC,b.surname,b.firstname LIMIT 10},$from,$to,@bind);
    return {flow=>$flow,cataloguing=>$cataloguing,cataloguers=>$cataloguers,top_titles=>$top_titles,fines=>$fines,overdue_bands=>$overdue_bands,itemtype_use=>$itemtype_use,day_hour=>$day_hour,borrowers_by_category=>$borrowers_by_category,new_borrowers=>$new_borrowers,top_borrowers=>$top_borrowers};
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

