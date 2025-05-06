
rsync_opt="-avz --no-perms --no-owner --no-group --exclude=.git/ --exclude=*.cpi --exclude=*.ppln"
p3_root="$HOME/eecs470/p3-w25.eshinj"
p4_root="$HOME/p4"

# fwd new programs/changes p3->p4
rsync $rsync_opt programs/ "$p3_root/programs/"
cd $p3_root
# generate correct outputs
./genp4.sh
# fwd correct outs p3->p4
rsync $rsync_opt output/ "$p4_root/correct_out/"
cd -

