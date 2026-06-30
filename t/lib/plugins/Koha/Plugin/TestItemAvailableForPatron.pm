package Koha::Plugin::TestItemAvailableForPatron;

## It's good practice to use Modern::Perl
use Modern::Perl;

## Required for all plugins
use base qw(Koha::Plugins::Base);

our $VERSION  = 1.00;
our $metadata = {
    name            => 'Test Plugin for item_available_for_patron',
    author          => 'Koha Dev',
    description     => 'Test plugin for the item_available_for_patron hook (Bug XXXXX)',
    date_authored   => '2026-06-30',
    date_updated    => '2026-06-30',
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

## Three-state hook (Bug XXXXX). Drives item.available_for_patron by the
## item's call number sentinel: 'PATRON-YES' forces available (true),
## 'PATRON-NO' forces unavailable (false), anything else abstains (undef) so the
## indexer falls back to its default conditions.
sub item_available_for_patron {
    my ( $self, $params ) = @_;
    my $item = $params->{item};
    return unless $item && $item->itemcallnumber;
    return 1     if $item->itemcallnumber eq 'PATRON-YES';
    return 0     if $item->itemcallnumber eq 'PATRON-NO';
    return;
}

1;
