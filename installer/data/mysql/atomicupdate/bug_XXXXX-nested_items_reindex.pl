use Modern::Perl;
use Koha::Installer::Output qw(say_warning say_info);

return {
    bug_number  => "XXXXX",
    description => "Warn that the Elasticsearch biblios index must be recreated for the nested items",
    up          => sub {
        my ($args) = @_;
        my ( $dbh, $out ) = @$args{qw(dbh out)};

        my ($search_engine) =
            $dbh->selectrow_array(q{SELECT value FROM systempreferences WHERE variable = 'SearchEngine'});

        if ( ( $search_engine // q{} ) eq 'Elasticsearch' ) {
            say_warning(
                $out,
                "The Elasticsearch biblios index must be recreated to search on the items of the records: "
                    . "run misc/search_tools/rebuild_elasticsearch.pl -b -d"
            );
            say_info(
                $out,
                "Until then, searches work as before: the item limits and facets do not combine on the same item"
            );
        } else {
            say_info( $out, "Nothing to do: the nested items are only used with Elasticsearch" );
        }
    },
};
