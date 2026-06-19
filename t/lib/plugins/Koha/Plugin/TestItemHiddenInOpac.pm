package Koha::Plugin::TestItemHiddenInOpac;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

our $VERSION  = 1.00;
our $metadata = {
    name            => 'Test Plugin for item_hidden_in_opac',
    author          => 'Koha Dev',
    description     => 'Test plugin for the item_hidden_in_opac hook (Bug XXXXX)',
    date_authored   => '2026-06-19',
    date_updated    => '2026-06-19',
    minimum_version => '21.11',
    maximum_version => undef,
    version         => $VERSION,
};

## This is the minimum code required for a plugin's 'new' method
## More can be added, but none should be removed
sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = $metadata;
    my $self = $class->SUPER::new($args);
    return $self;
}

## Hides items whose call number is the sentinel value. Returns 1 to hide the
## item in the OPAC, 0 otherwise.
sub item_hidden_in_opac {
    my ( $self, $params ) = @_;
    my $item = $params->{item};
    return ( $item && $item->itemcallnumber && $item->itemcallnumber eq 'HIDEME' ) ? 1 : 0;
}

1;
