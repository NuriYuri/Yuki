#===
#Yuki::VirtualDirectory
#  Classe de gestion de dossier virtuels plus rapides à charger
#---
#© 09/02/2015 - Nuri Yuri : Création du script
#===
module Yuki
  class VirtualDirectory
    Read='r'
    Write='w'
    WriteA='a'
    Both='a+'
    OpenMod="r+b"
    CreateMod="w+b"
    Free = :free?
    Free_Len = :free_len?
    Int="I"
    #===
    #>Structure d'un dossier virtuel : [Marshal_ptr,[size1,File1],[size2,File2],...,{Marshal_hash}]
    #===
    #===
    #>new
    # Ouverture/création d'un dossier virtuel
    #---
    #E : dir_name : String   Nom du dossier à ouvrir
    #    mod : String   Mode d'ouverture du dossier
    #===
    def initialize(dir_name, mod)
      @can_read = (mod.include?(Read) or mod.include?(Both))
      @can_write = (mod.include?(Write) or mod.include?(Both) or mod.include?(WriteA))
      @dir_name = dir_name
      @real_name = dir_name+"/00000000.dir"
      if(File.exist?(@real_name))
        @file = File.new(@real_name,OpenMod)
        @file.pos = 0
        marshal_pos = @file.read(4).unpack(Int)[0]
        if(marshal_pos>0)
          @file.pos = marshal_pos
          @path = Marshal.load(@file)
          @marshal_end = @file.pos
          @file_size = marshal_pos
        else
          print("Erreur, le dossier n'a pas bien été fermé, il en resulte une corruption de ses données.")
          @path = Hash.new
          @path[Free] = Array.new
          @path[Free_Len] = Array.new
          @file_size = 4
        end
      else
        expand_dir
        @file = File.new(@real_name,CreateMod)
        @file.write("\x00\x00\x00\x00")
        @path = Hash.new
        @path[Free] = Array.new
        @path[Free_Len] = Array.new
        @marshal_end = nil
        @file_size = 4
      end
      @last_exist_name = nil
      @last_exist_pos = nil
      #>C'est censé être appelé quand l'objet disparait mais ce n'est pas le cas
      ObjectSpace.define_finalizer(self, proc { close() })
    end
    #===
    #>read_file
    # Lis un fichier dans le dossier virtuel
    #---
    #E : file_name : String
    #S : data : String
    #===
    def read_file(file_name)
      return false unless @can_read
      return nil if @file.closed?
      pos = (@last_exist_name==file_name ? @last_exist_pos : @path[file_name])
      if(pos)
        @file.pos = pos
        size = @file.read(4).unpack(Int)[0]
        return @file.read(size)
      end
      return nil
    end
    #===
    #>file_exist?
    # Vérifie la présence d'un fichier
    #---
    #E : file_name : String
    #S : bool   Indique la présence ou non du fichier
    #===
    def file_exist?(file_name)
      pos = @path[file_name]
      if(pos)
        @last_exist_name = file_name
        @last_exist_pos = pos
        return true
      end
      return false
    end
    #===
    #>write_file
    # Ecrit un fichier dans le dossier virtuel
    #---
    #E : file_name : String   Nom du fichier
    #    data : String   Contenu du fichier
    #S : bool : ça a été écrit ou alors c'est pas ouvert pour l'écriture
    #V : existing_file : Fixnum / false   Fichier déjà existant
    #    file_size : Fixnum   Taille du fichier à écrire
    #===
    def write_file(file_name, data)
      return false unless @can_write
      return nil if @file.closed?
      file_size = data.bytesize
      existing_file = @path[file_name]
      if(existing_file)
        #>Le fichier existe, nous allons vérifier si on peut écraser le fichier
        #Ou devoir chercher aillseurs
        @file.pos = existing_file
        old_file_size = @file.read(4).unpack(Int)[0]
        if(old_file_size >= file_size)
          @file.pos = existing_file
          @file.write([file_size].pack(Int))
          @file.write(data)
          free_pos = @file.pos
          free_len = old_file_size - file_size
          register_free_part(free_pos, free_len)
        else
          register_free_part(existing_file, file_size+4)
          write_file_at_end_or_free(file_name, data, file_size)
        end
      else
        #>Le fichier n'existe pas, nous allons donc chercher à trouver de l'espace libre
        #Pour l'écrire ou alors l'écrire à la fin
        write_file_at_end_or_free(file_name, data, file_size)
      end
      return true
    end
    #===
    #>write_file_at_end
    # Ecrit le fichier à la fin du dossier
    #---
    #E : file_name : String   Nom du fichier
    #    data : String   contenu du fichier
    #    file_size : Fixnum   taille du fichier
    #===
    def write_file_at_end_or_free(file_name, data, file_size)
      #>On va chercher une partie libre contenant assez de mémoire
      free_part = get_free_part(file_size)
      if(free_part)
        @file.pos = free_part
        @file.write([file_size].pack(Int))
        @file.write(data)
        @path[file_name] = free_part
        return
      end
      #>On vérifie la présence du hash pour l'écraser
      if(@marshal_end)
        @file.pos = 0
        marshal_beg = @file.read(4).unpack(Int)[0]
        @file.write([file_size].pack(Int))
        @file.write(data)
        @path[file_name] = marshal_beg
        @marshal_end = nil
        @file_size+=(4+file_size-(@file_size-marshal_beg))
        return
      end
      #>On récupère la taille du fichier qui est grossièrement la fin et on écrit
      file_end = @file_size
      @file.pos = file_end
      @file.write([file_size].pack(Int))
      @file.write(data)
      @path[file_name] = file_end
      @file_size+=(4+file_size)
    end
    private :write_file_at_end_or_free
    #===
    #>get_free_part
    # Permet de récupérer une partie libre en fonction de la taille du data
    #---
    #E : file_size : Fixnum   Taille du fichier libre que l'on veut
    #S : Fixnum   Position dans le fichier de la partie libre
    #===
    def get_free_part(file_size)
      #>On va énumérer le tableau de taille des parties libres
      file_size += 4
      tbl = @path[Free_Len]
      found_index = nil
      tbl.each_index do |i|
        if(tbl[i]>=file_size)
          found_index = i
          break
        end
      end
      return nil unless found_index
      index_size = tbl[found_index]
      free_part = @path[Free][found_index]
      delta_size = index_size-file_size
      if(delta_size > 0)
        tbl[found_index] = delta_size
        @path[Free][found_index] += file_size
      else
        tbl.delete_at(found_index)
        @path[Free].delete_at(found_index)
      end
      return free_part
    end
    private :get_free_part
    #===
    #>register_free_part
    # Permet d'enregistrer une zone de donnée libre
    #---
    #E : file_pos : Fixnum   Position de la plage de données libre
    #    file_size : Fixnum  Taille de la plage de donénes libre
    #===
    def register_free_part(file_pos, file_size)
      #>On va rechercher si il y a pas une plage de données libre juste après
      free_pos = file_pos+file_size
      found_index = nil
      tbl = @path[Free]
      tbl.each_index do |i|
        if(free_pos == tbl[i])
          found_index = i
          break
        end
      end
      #>Si on a trouvé on met à jour la plage de donnée libre
      if(found_index)
        tbl[found_index] = file_pos
        @path[Free_Len][found_index] += file_size
        return
      end
      #>Sinn on enregistre la nouvelle plage
      @path[Free_Len]<<file_size
      tbl<<file_pos
    end
    private :register_free_part
    #===
    #>close
    # Ferme le dossier
    #===
    def close
      return if @file.closed?
      if(@can_write)
        file_size = @file_size
        @file.pos = 0
        @file.write([file_size].pack(Int))
        @file.pos = file_size
        Marshal.dump(@path, @file)
      end
      @file.close
    end
    #===
    #>expand_dir
    # Crée les dossier necessaires si non existants
    #===
    def expand_dir
      dirs = @dir_name.gsub("\\","/").split("/")
      current_dir = ""
      dirs.each do |i|
        current_dir << i
        current_dir << "/"
        unless File.exist?(current_dir)
          Dir.mkdir(current_dir)
        end
      end
    end
  end
end
