select saref, sum(saval), sum(sacost) from analysis where left(saproduct,1) = '3' group by saref
