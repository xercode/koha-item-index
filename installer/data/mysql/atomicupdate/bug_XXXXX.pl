use Modern::Perl;
use Koha::Installer::Output qw(say_warning say_success say_info);

return {
    bug_number  => "XXXXX",
    description => "Add StaffSearchResultsShowOnlyMatchingItems system preference",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        $dbh->do(
            q{
            INSERT IGNORE INTO systempreferences ( `variable`, `value`, `options`, `explanation`, `type` ) VALUES
            ('StaffSearchResultsShowOnlyMatchingItems','1',NULL,'If enabled, staff search results only list the items that match the search filters, with recomputed item counts (Elasticsearch only)','YesNo')
        }
        );

        say_success( $out, "Added new system preference 'StaffSearchResultsShowOnlyMatchingItems'" );
    },
};
